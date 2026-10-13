#!/usr/bin/perl
# Symphony's Claude Code `PreToolUse` hook for the Bash tool: it refuses a command that starts a
# macOS app. The agent sandbox denies the window server, so such a program can't draw, but it
# still checks in with LaunchServices, so when it crashes ReportCrash puts a "quit unexpectedly"
# dialog on the operator's desktop (TP-479).
#
# A program counts as an app when it is a Mach-O executable that names `NSApplication`,
# `NSApplicationMain`, `NSWindow`, `NSPanel`, `NSAlert`, `NSStatusBar` or SwiftUI's `App.main`,
# or a Swift script run with `swift <file>` that uses one of them. A program that only renders
# SwiftUI views offscreen with `ImageRenderer` names none of them. The hook looks at the program of
# each simple command in the line (after `VAR=value` and wrappers such as `env`, `exec` and
# `timeout`), following `cd`, and at the products `swift run` would start.
#
# Claude Code passes the tool call as JSON on stdin. Exit 2 refuses the command and shows stderr to
# the agent; anything else lets it run.
use strict;
use warnings;
use JSON::PP;
use Text::ParseWords qw(shellwords);
use File::Basename qw(basename);

my @app_symbols = (
  '_OBJC_CLASS_$_NSApplication', '_NSApplicationMain', '_OBJC_CLASS_$_NSWindow',
  '_OBJC_CLASS_$_NSPanel', '_OBJC_CLASS_$_NSAlert', '_OBJC_CLASS_$_NSStatusBar',
  '7SwiftUI3AppPAAE4main'
);
my $app_source = qr/\b(?:NSApplication|NSApplicationMain|NSApp|NSWindow|NSPanel|NSAlert|NSStatusBar|WindowGroup|MenuBarExtra)\b|:\s*App\s*\{/;
my %wrappers = map { $_ => 1 } qw(env exec command time nohup nice timeout gtimeout caffeinate arch then do else ! sudo);
my $chunk_size = 1 << 20;
my $overlap = 64;

my $input = do { local $/; <STDIN> };
my $event = eval { JSON::PP->new->decode($input) };
exit 0 unless ref $event eq 'HASH' && ref $event->{tool_input} eq 'HASH';
my $command = $event->{tool_input}{command};
exit 0 unless defined $command && !ref $command;
my $cwd = defined $event->{cwd} && !ref $event->{cwd} ? $event->{cwd} : '.';

for my $segment (split /\|\||&&|\$\(|[;&|\n()`{}]/, $command) {
  my @words = shellwords($segment);
  @words = split ' ', $segment unless @words;
  my ($program, @args) = program(@words);
  next unless defined $program;

  if ($program eq 'cd') {
    $cwd = resolve($args[0], $cwd) if @args;
  } elsif (basename($program) eq 'swift') {
    check_swift($cwd, @args);
  } elsif ($program =~ m{/}) {
    my $path = resolve($program, $cwd);
    refuse($program) if app_binary($path);
  }
}

exit 0;

# The program of a simple command and its arguments: the first word that is not a `VAR=value`
# assignment, a wrapper, or a wrapper's flag or number.
sub program {
  my @words = @_;
  my $after_wrapper = 0;

  while (@words) {
    my $word = $words[0];

    if ($word =~ /^[A-Za-z_][A-Za-z0-9_]*=/ || $wrappers{$word} || ($after_wrapper && $word =~ /^(?:-|\d+(?:\.\d+)?[smhd]?$)/)) {
      $after_wrapper = 1 if $wrappers{$word};
      shift @words;
    } else {
      return @words;
    }
  }

  return;
}

# `swift run [product]` starts the package's executables; `swift <file>` runs a Swift script.
sub check_swift {
  my ($dir, @args) = @_;
  my %options;
  my @plain;

  while (@args) {
    my $arg = shift @args;

    if ($arg =~ /^(?:--package-path|--scratch-path|-c|--configuration)$/) {
      $options{$arg} = shift @args;
    } elsif ($arg !~ /^-/) {
      push @plain, $arg;
    }
  }

  return unless @plain;

  if ($plain[0] eq 'run') {
    my $package = defined $options{'--package-path'} ? resolve($options{'--package-path'}, $dir) : $dir;
    my $build = defined $options{'--scratch-path'} ? resolve($options{'--scratch-path'}, $dir) : "$package/.build";
    my $configuration = $options{'-c'} // $options{'--configuration'} // 'debug';
    my $products = "$build/$configuration";
    my @candidates = defined $plain[1] ? ("$products/$plain[1]") : entries($products);

    for my $candidate (@candidates) {
      refuse("swift run " . basename($candidate)) if app_binary($candidate);
    }
  } elsif (my ($script) = grep { /\.swift$/ } @plain) {
    my $path = resolve($script, $dir);
    refuse("swift $script") if -f $path && contains_source($path);
  }
}

sub entries {
  my ($dir) = @_;
  opendir(my $dh, $dir) or return ();
  my @entries = map { "$dir/$_" } grep { !/^\.\.?$/ } readdir $dh;
  closedir $dh;
  return @entries;
}

sub resolve {
  my ($path, $dir) = @_;
  my $home = $ENV{HOME} // '';
  my $tmp = $ENV{TMPDIR} // '/tmp';
  $path =~ s{^~(?=/|$)}{$home};
  $path =~ s{\$\{?HOME\}?}{$home}g;
  $path =~ s{\$\{?TMPDIR\}?}{$tmp}g;
  $path =~ s{\$\{?PWD\}?}{$dir}g;
  return $path =~ m{^/} ? $path : "$dir/$path";
}

sub app_binary {
  my ($path) = @_;
  return 0 unless -f $path && -x _;
  open(my $fh, '<:raw', $path) or return 0;
  read($fh, my $magic, 4);
  my $macho = defined $magic && grep { $magic eq $_ } ("\xcf\xfa\xed\xfe", "\xce\xfa\xed\xfe", "\xca\xfe\xba\xbe", "\xbe\xba\xfe\xca");
  my $found = $macho ? scan($fh) : 0;
  close $fh;
  return $found;
}

# Reads the file in chunks, keeping the end of the last one so a name split between two chunks is
# still found.
sub scan {
  my ($fh) = @_;
  my $tail = '';

  while (read($fh, my $chunk, $chunk_size)) {
    my $window = $tail . $chunk;
    for my $symbol (@app_symbols) {
      return 1 if index($window, $symbol) >= 0;
    }
    $tail = substr($window, -$overlap);
  }

  return 0;
}

sub contains_source {
  my ($path) = @_;
  open(my $fh, '<', $path) or return 0;
  my $source = do { local $/; <$fh> };
  close $fh;
  return defined $source && $source =~ $app_source;
}

sub refuse {
  my ($what) = @_;
  print STDERR "Symphony refused this command: `$what` starts a macOS app (NSApplication, a window or an alert). "
    . "In the agent sandbox it can't draw, but when it crashes macOS puts a \"quit unexpectedly\" dialog on the operator's desktop. "
    . "Render SwiftUI views offscreen with ImageRenderer instead (no NSApplication, no window), "
    . "or leave the running app to the QA pass.\n";
  exit 2;
}
