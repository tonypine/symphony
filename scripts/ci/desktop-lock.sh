#!/bin/bash
# Runs a command while holding the desktop of a self-hosted Mac runner's VM.
#
#   desktop-lock.sh [--wait <minutes>] [--limit <minutes>] -- <command...>
#
# The ci-macos VM runs more than one GitHub Actions runner, and they share one login session: one
# screen, one keyboard, one home folder, one keychain search list. A step that puts a window on the
# screen, sends keys or clicks, launches the Symphony app or changes session-wide state (the keychain
# search list, crash-dialog defaults) takes this lock, so only one such step runs on the VM at a time.
# Builds and tests that use none of these run beside it.
#
# The lock is a flock(2) on $DESKTOP_LOCK_DIR/desktop.lock (default ~/.ci-locks): kernel state, freed
# the moment this wrapper exits, however it exits (SIGKILL included). The file's content only says
# who holds it; its existence means nothing. The command does not inherit the lock's descriptor
# (close-on-exec), so an app it leaves running can't keep the lock.
#
#   --wait <minutes>   how long to wait for the lock (default 15); then exit 75, naming the holder.
#                      While waiting it says who holds it, at the start and every 30 seconds.
#   --limit <minutes>  how long the command may run once the lock is held (default 10); then its
#                      process group is stopped and the wrapper exits 124. Fractions are allowed.
# A step's timeout-minutes is at least wait + limit, so a step waiting in line never reads as a hang.
# TERM, INT or HUP stop the command's process group, clean up and exit 128 + the signal.
# Otherwise it exits with the command's status.
#
# Cleanup, on taking the lock (a killed step can't clean up after itself, and an app started with
# `open` belongs to launchd, not to the step) and again on exit. It stops only what desktop steps
# start, never what the other runner's builds and tests may be running (swift, swiftc, xctest,
# *PackageTests, beam.smp under mise or _build, python, git, node):
#   - the previous holder's process group, as it wrote it in the lock file (skipped when that group's
#     leader is a newer process that reused the number);
#   - every process whose executable is named exactly SymphonyBar: the app, which only desktop steps
#     run (the ticket page test, the update test's bundles). Build steps build it but never run it;
#     the tests' bundle is SymphonyBarPackageTests, run by xctest;
#   - every process whose executable, or the script its interpreter runs, is under a
#     .../symphony-e2e/ folder: the update test's work root ($RUNNER_TEMP/symphony-e2e), whose app
#     starts its Symphony (beam.smp, epmd -daemon), the update helper and the stub agent in sessions
#     of their own. The smoke test's Symphony runs from $RUNNER_TEMP/smoke and is not matched.
#
# The SymphonyBar and symphony-e2e rules run only on a CI runner (GITHUB_ACTIONS=true): on a
# developer's Mac they would stop the Symphony app in use. Elsewhere only the previous holder's group
# is stopped.
# DESKTOP_LOCK_CLEANUP_ROOT (for tests): the name and path rules run, and match only processes whose
# executable or script is under that folder, so a test never stops a real app.
# DESKTOP_LOCK_NOTICE_SECONDS (for tests): how often a waiter says who holds the lock (default 30).
# The wrapper is Perl (macOS has no flock(1)); bash only hands it over.
IFS= read -r -d '' script <<'PERL' || true
use strict;
use warnings;
use Fcntl qw(:DEFAULT :flock F_GETFD F_SETFD FD_CLOEXEC);
use POSIX qw(:sys_wait_h strftime);
use Time::HiRes qw(time sleep);

$| = 1;
$ENV{LC_ALL} = 'C';
my %signal_number = (HUP => 1, INT => 2, TERM => 15);
my $caught;
$SIG{$_} = sub { $caught //= $_[0] } for keys %signal_number;

sub say_line { print STDERR "desktop-lock: @_\n" }
sub usage { say_line(@_) if @_; say_line('usage: desktop-lock.sh [--wait <minutes>] [--limit <minutes>] -- <command...>'); exit 2 }

my ($wait_minutes, $limit_minutes) = (15, 10);
while (@ARGV) {
  my $arg = shift @ARGV;
  if ($arg eq '--') { last }
  elsif ($arg eq '--wait' || $arg eq '--limit') {
    my $value = shift @ARGV;
    usage("$arg needs a number of minutes") unless defined $value && $value =~ /^\d+(\.\d+)?$/;
    if ($arg eq '--wait') { $wait_minutes = $value } else { $limit_minutes = $value }
  }
  else { usage("unknown option $arg") }
}
my @command = @ARGV;
usage('no command given') unless @command;

my $dir = $ENV{DESKTOP_LOCK_DIR} || "$ENV{HOME}/.ci-locks";
my $notice_seconds = $ENV{DESKTOP_LOCK_NOTICE_SECONDS} || 30;
my $cleanup_root = $ENV{DESKTOP_LOCK_CLEANUP_ROOT};
$cleanup_root =~ s{/+$}{} if defined $cleanup_root;
my $path = "$dir/desktop.lock";

unless (-d $dir) { mkdir $dir or -d $dir or die "desktop-lock: can't create $dir: $!\n" }
sysopen(my $lock, $path, O_RDWR | O_CREAT, 0644) or die "desktop-lock: can't open $path: $!\n";
fcntl($lock, F_SETFD, fcntl($lock, F_GETFD, 0) | FD_CLOEXEC) or die "desktop-lock: close-on-exec: $!\n";

# --- who holds it ---------------------------------------------------------------------------------

sub read_holder {
  open(my $in, '<', $path) or return {};
  my %holder;
  while (my $line = <$in>) { chomp $line; $holder{$1} = $2 if $line =~ /^(\w+)=(.*)$/ }
  return \%holder;
}

sub describe {
  my ($holder) = @_;
  return 'an unknown holder' unless $holder->{runner};
  my @about = grep { defined && length } @$holder{qw(workflow job ref)};
  my $text = $holder->{runner};
  $text .= ' (' . join(', ', @about) . ')' if @about;
  $text .= " running $holder->{command}" if $holder->{command};
  $text .= ' since ' . strftime('%H:%M', localtime $holder->{started}) if $holder->{started};
  $text .= ", $holder->{url}" if $holder->{url};
  return $text;
}

sub write_holder {
  my (%extra) = @_;
  my $ref = $ENV{GITHUB_REF} // '';
  my $where = $ref =~ m{^refs/pull/(\d+)/} ? "PR #$1" : ($ENV{GITHUB_REF_NAME} // '');
  my $url = $ENV{GITHUB_RUN_ID} && $ENV{GITHUB_REPOSITORY}
    ? ($ENV{GITHUB_SERVER_URL} || 'https://github.com') . "/$ENV{GITHUB_REPOSITORY}/actions/runs/$ENV{GITHUB_RUN_ID}" : '';
  my $shown = join(' ', @command);
  # A workflow step runs as `bash -e <its script>`: its first line says more than the script's path.
  if (@command >= 2 && $command[0] =~ m{(?:^|/)(?:ba)?sh$} && -f $command[-1] && open(my $in, '<', $command[-1])) {
    my @lines = grep { /\S/ } <$in>;
    if (@lines) { ($shown = $lines[0]) =~ s/^\s+|\s+$//g; $shown .= ' ...' if @lines > 1 }
  }
  $shown =~ s/\n/ /g;
  $shown = substr($shown, 0, 200) . '...' if length $shown > 200;
  my %holder = (
    runner => $ENV{RUNNER_NAME} || ((getpwuid $<)[0] . '@' . (`hostname -s 2>/dev/null` =~ s/\s+$//r)),
    workflow => $ENV{GITHUB_WORKFLOW} // '', job => $ENV{GITHUB_JOB} // '', ref => $where, url => $url,
    command => $shown, started => int(time), pid => $$, %extra,
  );
  my $text = join('', map { "$_=$holder{$_}\n" } sort keys %holder);
  truncate($lock, 0); sysseek($lock, 0, 0); syswrite($lock, $text);
}

sub clear_holder { truncate($lock, 0) }

# --- the lock -------------------------------------------------------------------------------------

my $waited_since = time;
my $deadline = $waited_since + $wait_minutes * 60;
my $next_notice = 0;
until (flock($lock, LOCK_EX | LOCK_NB)) {
  exit 128 + $signal_number{$caught} if $caught;
  my $now = time;
  if ($now >= $deadline) {
    say_line("Desktop busy for $wait_minutes min, held by " . describe(read_holder()));
    exit 75;
  }
  if ($now >= $next_notice) {
    say_line('Waiting for the desktop: held by ' . describe(read_holder()));
    $next_notice = $now + $notice_seconds;
  }
  sleep 0.2;
}
my $waited = time - $waited_since;
say_line(sprintf('took the desktop after %.0f s', $waited)) if $waited >= 1;

# --- cleanup --------------------------------------------------------------------------------------

sub processes {
  my %all;
  open(my $ps, '-|', '/bin/ps', '-axww', '-o', 'pid=,ppid=,pgid=,lstart=,comm=') or return {};
  while (<$ps>) {
    $all{$1} = { ppid => $2, pgid => $3, start => $4, exe => $5 }
      if /^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\w{3}\s+\w{3}\s+\d+\s+[\d:]{8}\s+\d{4})\s+(.*?)\s*$/;
  }
  close $ps;
  open($ps, '-|', '/bin/ps', '-axww', '-o', 'pid=,args=') or return \%all;
  while (<$ps>) { $all{$1}{args} = $2 if /^\s*(\d+)\s+(.*?)\s*$/ && $all{$1} }
  close $ps;
  return \%all;
}

sub start_of { my ($pid) = @_; my $p = processes()->{$pid}; return $p ? $p->{start} : '' }

# The executable, and the script an interpreter runs (`/bin/sh /path/script`): the paths a rule looks at.
sub paths_of {
  my ($p) = @_;
  my @words = split ' ', ($p->{args} // '');
  return grep { defined && m{^/} } ($p->{exe}, $words[1]);
}

sub under_root {
  my (@paths) = @_;
  return 1 unless defined $cleanup_root && length $cleanup_root;
  return scalar grep { index($_, "$cleanup_root/") == 0 } @paths;
}

# The name and path rules run only on a CI runner (or in a test, under its root): on a developer's Mac
# they would stop the Symphony app in use.
my $sweep = (defined $cleanup_root && length $cleanup_root) || ($ENV{GITHUB_ACTIONS} // '') eq 'true';

sub desktop_leftover {
  my ($p) = @_;
  return 0 unless $sweep;
  my @paths = paths_of($p);
  return 0 unless under_root(@paths);
  return 1 if ($p->{exe} // '') =~ m{(?:^|/)SymphonyBar$};
  return 1 if grep { m{/symphony-e2e/} } @paths;
  return 0;
}

sub stop_pids {
  my ($why, @pids) = @_;
  return unless @pids;
  say_line("stopping $why: " . join(', ', @pids));
  kill 'TERM', @pids;
  for (1 .. 30) {
    my $all = processes();
    @pids = grep { $all->{$_} } @pids;
    return unless @pids;
    sleep 0.1;
  }
  kill 'KILL', @pids;
}

sub cleanup {
  my (%group) = @_;    # pgid, start: a process group to stop as a whole
  my $own_pgid = getpgrp();
  my $all = processes();
  my %spare = (1 => 1);
  for (my $pid = $$; $pid > 1 && !$spare{$pid}; $pid = $all->{$pid} ? $all->{$pid}{ppid} : 1) { $spare{$pid} = 1 }
  if (my $pgid = $group{pgid}) {
    my $leader = $all->{$pgid};
    my $same = !$leader || !$group{start} || $leader->{start} eq $group{start};
    my @members = grep { $all->{$_}{pgid} == $pgid && !$spare{$_} } keys %$all;
    if ($pgid != $own_pgid && $same && @members) {
      stop_pids("what process group $pgid left", sort { $a <=> $b } @members);
      $all = processes();
    }
  }
  my @leftovers = grep { !$spare{$_} && desktop_leftover($all->{$_}) } keys %$all;
  stop_pids('the desktop apps left running', sort { $a <=> $b } @leftovers);
}

my $previous = read_holder();
cleanup(pgid => $previous->{pgid}, start => $previous->{pgid_start});
write_holder();

# --- the command ----------------------------------------------------------------------------------

my $child = fork();
die "desktop-lock: fork: $!\n" unless defined $child;
if ($child == 0) {
  $SIG{$_} = 'DEFAULT' for keys %signal_number;
  setpgrp(0, 0);
  exec { $command[0] } @command or do { print STDERR "desktop-lock: can't run $command[0]: $!\n"; POSIX::_exit(127) };
}
setpgrp($child, $child);    # either side may run first
write_holder(pgid => $child, pgid_start => start_of($child));

my $limit_at = time + $limit_minutes * 60;
my ($status, $outcome);
while (1) {
  my $done = waitpid($child, WNOHANG);
  if ($done == $child) { $status = $?; last }
  if ($caught) { $outcome = $caught; last }
  if (time >= $limit_at) { $outcome = 'limit'; last }
  sleep 0.1;
}

sub finish {
  my ($code) = @_;
  cleanup(pgid => $child);
  clear_holder();
  exit $code;
}

if (!defined $outcome) {
  finish(WIFEXITED($status) ? WEXITSTATUS($status) : 128 + WTERMSIG($status));
}
if ($outcome eq 'limit') {
  say_line("the command ran past its $limit_minutes min limit; stopping it: @command");
} else {
  say_line("caught SIG$outcome; stopping the command");
}
kill 'TERM', -$child;
for (1 .. 50) { last if waitpid($child, WNOHANG) == $child; sleep 0.1 }
kill 'KILL', -$child;
waitpid($child, 0);
finish($outcome eq 'limit' ? 124 : 128 + $signal_number{$outcome});
PERL
exec /usr/bin/perl -e "$script" -- "$@"
