#!/usr/local/bin/perl
#
# =====================================================================
#  atualiza_tor_list.pl — pfSense IPv4 TOR Exit IP Updater (merged feeds)
#  Version: 1.4.0  (2025-09-20)
#
#  Purpose
#  -------
#  Download TOR exit-node IPs from reliable sources, keep only IPv4,
#  merge/dedupe the results, compare with the current list, and only
#  update the pf table if there is an actual change (short-circuit).
#  Designed for pfSense 2.7.x / FreeBSD.
#
#  Sources (merged, with per-source counters):
#    1) Onionoo (Tor Project JSON API) — exit_addresses of running exits
#    2) Tor "exit-addresses" text feed (authoritative, plain text)
#    3) (Optional) dan.me.uk/torlist  (plain text; may 403/rate-limit)
#
#  pf Table
#  --------
#  Default pf table name: _Tor_IP_List_   (adjust in CONFIG if needed)
#
#  Credits
#  -------
#  Based on the original script by:
#    "Aurelio de Souza Ribeiro Neto — atualiza_tor_list.pl (2016-12-29)"
#  Modernized, hardened, merged feeds, and extended by:
#    ChatGPT (GPT-5 Thinking), 2025
#
#  Changelog
#  ---------
#    1.4.0 (2025-09-20)
#      - Merge logic: Onionoo + exit-addresses (+ optional dan.me.uk)
#      - Per-source addition counters and clean summary line
#      - Stable sorted output for consistent diff/cmp
#      - Refined logging (info/warn/debug), clearer reasons
#    1.3.0 (2025-09-20)
#      - Robust Onionoo parsing (multiline JSON slurp)
#      - Added Tor “exit-addresses” fallback
#      - Verbosity levels; IPv4-only; short-circuit cmp -s
#      - Atomic replace; correct pfctl invocation order
#      - Optional primary source via feature flag
#
#  License
#  -------
#  Use at your own risk. No warranty. Keep credits when redistributing.
# =====================================================================

use strict;
use warnings;
use Fcntl qw(:flock);
use File::Copy qw(move);

# =========================== CONFIG ===========================
# Feature flags
my $USE_DANME   = 0;   # 1 = also fetch/merge dan.me.uk/torlist; 0 = skip
my $VERBOSE     = 1;   # 0 = quiet (cron-friendly), 1 = info, 2 = debug

# Paths
my $dir_base    = '/usr/local/www/aliastables';
my $file_final  = "$dir_base/iplist";         # production list (IPv4 only)
my $lockfile    = '/var/run/atualiza_tor_list.lock';

# Temporary files (unique by PID)
my $tmp_base    = "$dir_base/iplist.$$";
my $tmp_onionoo = "$tmp_base.onionoo";        # parsed Onionoo → plain IPv4 lines
my $tmp_exit    = "$tmp_base.exit";           # parsed exit-addresses → plain IPv4 lines
my $tmp_dan     = "$tmp_base.dan";            # dan.me.uk → plain IPv4 lines
my $tmp_merged  = "$tmp_base.merged";         # merged/deduped candidate (IPv4 only)

# pf / binaries
my $table_name  = '_Tor_IP_List_';
my $pfctl       = '/sbin/pfctl';
my $fetch       = '/usr/bin/fetch';
my $cmpbin      = '/usr/bin/cmp';

# Sources
my $URL_ONIONOO = 'https://onionoo.torproject.org/details?type=relay&running=true&flag=Exit&fields=exit_addresses';
my $URL_EXITTXT = 'https://check.torproject.org/exit-addresses';
my $URL_DANME   = 'https://www.dan.me.uk/torlist'; # no trailing slash (avoid fetch quirks)

# Fetch defaults
my $FETCH_TIMEOUT = 30;   # seconds
my $UA_BROWSER    = 'Mozilla/5.0 (X11; FreeBSD) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36';

# ======================== LOG HELPERS =========================
sub log_info  { print "[info]  @_","\n"  if $VERBOSE >= 1 }
sub log_warn  { print "[warn]  @_","\n"  if $VERBOSE >= 1 }
sub log_debug { print "[debug] @_","\n"  if $VERBOSE >= 2 }
sub die_with  { my ($msg) = @_; print "[error] $msg\n"; exit 1; }

# ======================== UTILITIES ===========================
# Strict IPv4 (with optional /CIDR 0..32) and octet bounds 0..255
sub is_ipv4 {
    my ($ip) = @_;
    return 0 unless $ip =~ /^(\\d{1,3}\\.){3}\\d{1,3}(?:\\/(?:\\d|[12]\\d|3[0-2]))?$/;
    my ($addr, $cidr) = split('/', $ip, 2);
    my @o = split(/\\./, $addr);
    for my $oct (@o) { return 0 if $oct < 0 || $oct > 255 }
    return 1;
}

# Quick check if file contains at least one IPv4 line
sub file_has_ipv4 {
    my ($path) = @_;
    open my $fh, '<', $path or return 0;
    while (my $l = <$fh>) {
        $l =~ s/^\\s+|\\s+$//g;
        next if $l eq '' || $l =~ /^#/;
        if (is_ipv4($l)) { close $fh; return 1; }
    }
    close $fh;
    return 0;
}

# Remove non-IPv4 lines and normalize spacing; write IPv4-only file
sub filter_to_ipv4 {
    my ($src, $dst) = @_;
    open my $IN,  '<', $src or die_with("cannot open $src");
    open my $OUT, '>', $dst or die_with("cannot open $dst for writing");
    while (my $l = <$IN>) {
        $l =~ s/^\\s+|\\s+$//g;
        next if $l eq '' || $l =~ /^#/;
        print $OUT "$l\\n" if is_ipv4($l);
    }
    close $IN;
    close $OUT;
}

# Atomic replace (rename within same filesystem) with best-effort backup
sub atomic_replace {
    my ($src, $dst) = @_;
    if (-e $dst) {
        my $bak = "$dst.bak";
        unlink $bak;
        move($dst, $bak);  # ignore failure (best effort)
    }
    move($src, $dst) or die_with("atomic move failed: $src -> $dst ($!)");
}

# Silent binary compare; returns 1 if equal, 0 if different
sub cmp_equal {
    my ($a, $b) = @_;
    return 0 unless -e $a && -e $b;  # treat missing as different
    my $rc = system($cmpbin, '-s', $a, $b);
    my $code = $rc >> 8; # 0 equal; 1 different; 2 error
    die_with("cmp failed with code 2") if $code == 2;
    return $code == 0 ? 1 : 0;
}

sub safe_unlink { my ($p) = @_; unlink $p if defined $p && -e $p; }

# ======================== FETCH HELPERS =======================
# run_fetch($url, $outfile, $user_agent_opt)
# - Uses env HTTP_USER_AGENT for compatibility across fetch versions.
# - Returns: (success_boolean, bytes_written)
sub run_fetch {
    my ($url, $outfile, $ua) = @_;
    safe_unlink($outfile);
    my @cmd;
    if (defined $ua && $ua ne '') {
        @cmd = ('sh','-c', qq{env HTTP_USER_AGENT="$ua" $fetch -q -T $FETCH_TIMEOUT -o "$outfile" "$url" 2>/dev/null});
    } else {
        @cmd = ($fetch, '-q', '-T', $FETCH_TIMEOUT, '-o', $outfile, $url);
    }
    log_debug("running: @cmd");
    my $rc = system(@cmd);
    my $ok = ($rc == 0) && -e $outfile && -s $outfile;
    my $sz = $ok ? (-s $outfile) : 0;
    return ($ok, $sz);
}

# Parse Onionoo JSON → write IPv4 (one per line) to $out_path
# Robust to multiline JSON; returns number of IPv4 written
sub parse_onionoo_to_file {
    my ($json_path, $out_path) = @_;
    open my $IN, '<', $json_path or return 0;
    local $/; my $json = <$IN>; close $IN;

    unless ($json =~ /"exit_addresses"\\s*:/) {
        log_debug("Onionoo: 'exit_addresses' key not found");
        return 0;
    }

    open my $OUT, '>', $out_path or return 0;
    my $count = 0;
    while ($json =~ /"exit_addresses"\\s*:\\s*\\[([^\\]]*)\\]/gms) {
        my $list = $1;
        my @ips = ($list =~ /"([^"]+)"/g);
        for my $ip (@ips) {
            $ip =~ s/^\\s+|\\s+$//g;
            if (is_ipv4($ip)) { print $OUT "$ip\\n"; $count++; }
        }
    }
    close $OUT;
    return $count;
}

# Parse Tor "exit-addresses" plaintext → write IPv4 to $out_path
# Lines look like: "ExitAddress 1.2.3.4 2025-09-20 12:34:56"
# Returns number of IPv4 written
sub parse_exitaddresses_to_file {
    my ($txt_path, $out_path) = @_;
    open my $IN,  '<', $txt_path or return 0;
    open my $OUT, '>', $out_path or return 0;
    my $count = 0;
    while (my $l = <$IN>) {
        if ($l =~ /^ExitAddress\\s+(\\d+\\.\\d+\\.\\d+\\.\\d+)\\b/) {
            my $ip = $1;
            if (is_ipv4($ip)) { print $OUT "$ip\\n"; $count++; }
        }
    }
    close $IN;
    close $OUT;
    return $count;
}

# Merge helpers: maintain a set of unique IPv4 strings in memory
sub merge_ipv4_file_into_set {
    my ($src, $setref) = @_;
    return 0 unless -e $src && -s $src;
    my $added = 0;
    open my $IN, '<', $src or return 0;
    while (my $l = <$IN>) {
        $l =~ s/^\\s+|\\s+$//g;
        next if $l eq '' || $l =~ /^#/;
        next unless is_ipv4($l);
        unless (exists $setref->{$l}) {
            $setref->{$l} = 1;
            $added++;
        }
    }
    close $IN;
    return $added;
}

# Materialize set to file (sorted for stable diff/cmp)
sub write_set_to_file {
    my ($setref, $dst) = @_;
    open my $OUT, '>', $dst or die_with("cannot open $dst for writing");
    for my $ip (sort { $a cmp $b } keys %$setref) { print $OUT "$ip\\n" }
    close $OUT;
    return scalar keys %$setref;
}

# ============================ MAIN ============================
# Lock to avoid concurrent runs
open my $LOCK, '>', $lockfile or die_with("cannot open lockfile $lockfile");
flock($LOCK, LOCK_EX | LOCK_NB) or die_with("another instance is already running");

-d $dir_base or die_with("base directory $dir_base does not exist");

# Per-source counters for reporting
my $cnt_onionoo  = 0;
my $cnt_exitaddr = 0;
my $cnt_danme    = 0;

# ---------------- 1) Onionoo (preferred) ----------------
log_info("fetching Onionoo (Tor Project JSON)");
my ($succ_oo, $bytes_oo) = run_fetch($URL_ONIONOO, "$tmp_onionoo.json", '');
if ($succ_oo) {
    log_debug("Onionoo bytes=$bytes_oo");
    $cnt_onionoo = parse_onionoo_to_file("$tmp_onionoo.json", $tmp_onionoo);
    safe_unlink("$tmp_onionoo.json");
    if ($cnt_onionoo > 0) {
        log_info("Onionoo OK ($cnt_onionoo IPv4 candidates)");
    } else {
        log_warn("Onionoo parsed but found no IPv4 exit addresses");
        safe_unlink($tmp_onionoo);
    }
} else {
    log_warn("Onionoo download failed; will still try other sources");
    safe_unlink("$tmp_onionoo.json");
}

# ------------- 2) Tor "exit-addresses" (authoritative) -------------
log_info("fetching Tor exit-addresses (plain text)");
my ($succ_ex, $bytes_ex) = run_fetch($URL_EXITTXT, "$tmp_exit.raw", '');
if ($succ_ex) {
    log_debug("exit-addresses bytes=$bytes_ex");
    $cnt_exitaddr = parse_exitaddresses_to_file("$tmp_exit.raw", $tmp_exit);
    safe_unlink("$tmp_exit.raw");
    if ($cnt_exitaddr > 0) {
        log_info("exit-addresses OK ($cnt_exitaddr IPv4 candidates)");
    } else {
        log_warn("exit-addresses parsed but found no IPv4");
        safe_unlink($tmp_exit);
    }
} else {
    log_warn("exit-addresses download failed");
    safe_unlink("$tmp_exit.raw");
}

# ---------------- 3) (Optional) dan.me.uk ----------------
if ($USE_DANME) {
    log_info("fetching dan.me.uk (plain text)");
    my ($succ_dm, $bytes_dm) = run_fetch($URL_DANME, "$tmp_dan.raw", $UA_BROWSER);
    if ($succ_dm) {
        # Filter only IPv4 lines into $tmp_dan
        filter_to_ipv4("$tmp_dan.raw", $tmp_dan);
        safe_unlink("$tmp_dan.raw");
        if (file_has_ipv4($tmp_dan)) {
            log_info("dan.me.uk OK (plain list fetched)");
        } else {
            log_warn("dan.me.uk fetched but contained no valid IPv4");
            safe_unlink($tmp_dan);
        }
    } else {
        log_warn("dan.me.uk download failed (likely 403 or rate-limit)");
        safe_unlink("$tmp_dan.raw");
    }
}

# Ensure at least one source produced data
if (!( (-e $tmp_onionoo && -s $tmp_onionoo) ||
       (-e $tmp_exit    && -s $tmp_exit)    ||
       (-e $tmp_dan     && -s $tmp_dan) )) {
    die_with("no valid IPv4 from any source (Onionoo/exit-addresses/dan.me.uk)");
}

# ---------------- 4) Merge & Deduplicate -----------------
my %seen = ();
my $added_from_onionoo  = merge_ipv4_file_into_set($tmp_onionoo, \%seen);
my $added_from_exitaddr = merge_ipv4_file_into_set($tmp_exit,    \%seen);
my $added_from_danme    = merge_ipv4_file_into_set($tmp_dan,     \%seen);

safe_unlink($tmp_onionoo);
safe_unlink($tmp_exit);
safe_unlink($tmp_dan);

my $total_after_merge = write_set_to_file(\%seen, $tmp_merged);
($total_after_merge > 0) or die_with("post-merge: no IPv4 to apply");

log_info(sprintf(
    "merged set: %d IPv4 (added: onionoo=%d, exit-addresses=%d%s)",
    $total_after_merge,
    $added_from_onionoo,
    $added_from_exitaddr,
    $USE_DANME ? ", dan.me.uk=$added_from_danme" : ""
));

# ------------- 5) Short-circuit (apply only if changed) -------------
if (-e $file_final && cmp_equal($tmp_merged, $file_final)) {
    safe_unlink($tmp_merged);
    log_info("no changes — table is already up to date");
    exit 0;
}

# ------------- 6) Atomic replace + pfctl update ---------------------
atomic_replace($tmp_merged, $file_final);

# Ensure table exists before replace
system($pfctl, '-t', $table_name, '-T', 'show') == 0
    or die_with("pf table '$table_name' does not exist — create an Alias URL Table with this name in GUI");

# Apply (quiet)
system($pfctl, '-q', '-t', $table_name, '-T', 'replace', '-f', $file_final) == 0
    or die_with("pfctl replace failed");

# Final count via pfctl (source of truth)
my $count = 0;
open my $SH, "-|", $pfctl, '-t', $table_name, '-T', 'show'
    or do { print "Updated.\\n"; exit 0; };
$count++ while (<$SH>);
close $SH;

# Build concise source summary
my @parts;
push @parts, "onionoo+$added_from_onionoo"   if $added_from_onionoo  > 0;
push @parts, "exitaddr+$added_from_exitaddr" if $added_from_exitaddr > 0;
push @parts, "danme+$added_from_danme"       if $USE_DANME && $added_from_danme > 0;
my $src_summary = @parts ? join(',', @parts) : 'no-new-sources';

print "Updated: $count IPv4 in table $table_name (sources: $src_summary)\\n";
exit 0;
