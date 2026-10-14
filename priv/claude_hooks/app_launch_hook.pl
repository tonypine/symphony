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
# A program the same line builds isn't on disk yet, so the hook also remembers what an earlier
# command builds from app sources: the output of `swiftc`, `clang`, `cc` or `gcc` (also through
# `xcrun`), and the products of `swift build`. A source file the line writes itself (a heredoc)
# isn't on disk either, so then the line's own text counts as the source; any other missing source
# is not an app. `swift run` of a package is judged by its sources. A copy of an app (`cp`, `mv`,
# `ln`) is an app too, and the line a shell runs with `-c` (`bash -c '...'`) is checked like the
# outer one. A program named through a variable (`$P`) or started by a script is not seen.
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
my %copiers = map { $_ => 1 } qw(cp mv ln ditto install rsync);
my %compilers = map { $_ => 1 } qw(swiftc clang clang++ cc c++ gcc g++);
my $source_file = qr/\.(?:swift|m|mm|c|cc|cpp)$/;
my $chunk_size = 1 << 20;
my $overlap = 64;

my $input = do { local $/; <STDIN> };
my $event = eval { JSON::PP->new->decode($input) };
exit 0 unless ref $event eq 'HASH' && ref $event->{tool_input} eq 'HASH';
my $command = $event->{tool_input}{command};
exit 0 unless defined $command && !ref $command;
my $cwd = defined $event->{cwd} && !ref $event->{cwd} ? $event->{cwd} : '.';
# Names of the files the line writes with a redirect or `tee`.
my %written = map { basename($_) => 1 } $command =~ /(?:>>?|\btee(?:\s+-a)?)\s*['"]?([^\s'";&|()<>]+)/g;
# Paths an earlier command in the line builds from app sources.
my %built_apps;
# `[build dir, product]` pairs an earlier `swift build` builds from app sources.
my @built_products;

check_line($command, $cwd);
exit 0;

# Checks each simple command of a line, in order, so `cd` and what earlier commands build carry
# over to the later ones.
sub check_line {
  my ($line, $dir) = @_;

  # `bash -c '<line>'` runs a line of its own, which the split below would cut at its separators:
  # check it whole first.
  while ($line =~ /\b(?:sh|bash|zsh|dash|ksh)\s+(?:-\w+\s+)*-\w*c\s+(?:'([^']*)'|"([^"]*)"|([^\s;&|]+))/g) {
    check_line($1 // $2 // $3, $dir);
  }

  for my $segment (split /\|\||&&|\$\(|[;&|\n()`{}]/, $line) {
    my @words = shellwords($segment);
    @words = split ' ', $segment unless @words;
    my ($program, @args) = program(@words);
    next unless defined $program;

    ($program, @args) = xcrun_tool(@args) if basename($program) eq 'xcrun';
    next unless defined $program;
    my $name = basename($program);

    if ($program eq 'cd') {
      $dir = resolve($args[0], $dir) if @args;
    } elsif ($name eq 'swift') {
      check_swift($dir, @args);
    } elsif ($compilers{$name}) {
      compile($program, $dir, @args);
    } elsif ($copiers{$name}) {
      copy($dir, @args);
    } elsif ($program =~ m{/}) {
      my $path = resolve($program, $dir);
      refuse($program) if app_path($path);
    }
  }
}

sub app_path {
  my ($path) = @_;
  return $built_apps{$path} || built_product($path) || app_binary($path);
}

# A copy of an app is an app: `cp probe x && ./x`.
sub copy {
  my ($dir, @args) = @_;
  my @paths = map { resolve($_, $dir) } grep { !/^-/ } @args;
  return unless @paths >= 2;

  my $target = pop @paths;
  for my $source (grep { app_path($_) } @paths) {
    # The target may be a folder the line creates first, so take both readings.
    $built_apps{$_} = 1 for ($target, "$target/" . basename($source));
  }
}

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

# The tool `xcrun [--sdk name] tool` runs.
sub xcrun_tool {
  my @args = @_;

  while (@args && $args[0] =~ /^-/) {
    my $flag = shift @args;
    shift @args if $flag =~ /^(?:-sdk|--sdk|-toolchain|--toolchain)$/;
  }

  return @args;
}

# Remembers the output of a compiler run on app sources: `-o <path>`, or the compiler's default
# (`swiftc` names it after the first source, the C compilers write `a.out`).
sub compile {
  my ($program, $dir, @args) = @_;
  my ($output, @sources);

  while (@args) {
    my $arg = shift @args;

    if ($arg eq '-o') {
      $output = shift @args;
    } elsif ($arg eq '-' || $arg =~ $source_file) {
      push @sources, $arg;
    }
  }

  return unless grep { app_source($_ eq '-' ? '-' : resolve($_, $dir)) } @sources;

  $output //= basename($program) eq 'swiftc' ? basename($sources[0], '.swift') : 'a.out';
  $built_apps{resolve($output, $dir)} = 1;
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

  if ($plain[0] eq 'run' || $plain[0] eq 'build') {
    my $package = defined $options{'--package-path'} ? resolve($options{'--package-path'}, $dir) : $dir;
    my $build = defined $options{'--scratch-path'} ? resolve($options{'--scratch-path'}, $dir) : "$package/.build";
    my $configuration = $options{'-c'} // $options{'--configuration'} // 'debug';
    my $products = "$build/$configuration";
    # A package's executable product is usually named after its target, a folder in `Sources`.
    my @app_targets = grep { grep { contains_source($_) } files_under("$package/Sources/$_") } map { basename($_) } entries("$package/Sources");

    if ($plain[0] eq 'build') {
      push @built_products, map { [$build, $_] } @app_targets;
      return;
    }

    my @candidates = defined $plain[1] ? ("$products/$plain[1]") : entries($products);
    for my $candidate (@candidates) {
      refuse("swift run " . basename($candidate)) if app_binary($candidate);
    }

    # `swift run` builds the product first, so its sources decide too, built or not.
    my @unbuilt = defined $plain[1] ? grep { $_ eq $plain[1] } @app_targets : @app_targets;
    refuse("swift run $unbuilt[0]") if @unbuilt;
  } elsif (my ($script) = grep { /\.swift$/ } @plain) {
    my $path = resolve($script, $dir);
    refuse("swift $script") if app_source($path);
  }
}

sub entries {
  my ($dir) = @_;
  opendir(my $dh, $dir) or return ();
  my @entries = map { "$dir/$_" } grep { !/^\.\.?$/ } readdir $dh;
  closedir $dh;
  return @entries;
}

# A product of an earlier `swift build`, which lands in `<build>/<triple>/<configuration>`, with
# `<build>/<configuration>` linking to it.
sub built_product {
  my ($path) = @_;
  return grep { index($path, "$_->[0]/") == 0 && basename($path) eq $_->[1] } @built_products;
}

sub files_under {
  my ($path) = @_;
  return () if -l $path && -d $path;
  return -f $path ? ($path) : map { files_under($_) } entries($path);
}

sub resolve {
  my ($path, $dir) = @_;
  my $home = $ENV{HOME} // '';
  my $tmp = $ENV{TMPDIR} // '/tmp';
  $path =~ s{^~(?=/|$)}{$home};
  $path =~ s{\$\{?HOME\}?}{$home}g;
  $path =~ s{\$\{?TMPDIR\}?}{$tmp}g;
  $path =~ s{\$\{?PWD\}?}{$dir}g;
  $path = "$dir/$path" unless $path =~ m{^/};
  # `./fresh` and `fresh` name the same file.
  1 while $path =~ s{/\.(?=/|$)}{} || $path =~ s{//}{/};
  1 while $path =~ s{/(?!\.\.(?:/|$))[^/]+/\.\.(?=/|$)}{};
  return $path;
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

# A source file that starts an app. One the line itself writes (`cat > new.swift <<EOF`, `tee`) or
# reads from stdin (`-`) isn't on disk yet, so the line's own text stands in for it. Any other
# missing file is not an app.
sub app_source {
  my ($path) = @_;
  return contains_source($path) if -f $path;
  return ($path eq '-' || $written{basename($path)}) && $command =~ $app_source;
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
