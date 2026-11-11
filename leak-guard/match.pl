#!/usr/bin/env perl
# Match a stream of text lines against public patterns and a private stoplist.
# Pure: reads stdin, prints hits, touches nothing else. Exit 0 clean, 1 hits, 2 error.
#
#   match.pl --patterns FILE [--stoplist FILE] --repo NAME [--redact]
#   match.pl --validate --stoplist FILE
#
# Stdin: one line per checked line of text, "<loc>TAB<path>TAB<text>".
# Stdout: one line per hit, "<loc> <rule-id> <fragment>"; --redact drops the
# fragment, so nothing that matched is ever printed.
# Rule ids: patterns#<line number in the file>, stoplist#<record number>;
# comments and blank lines do not count as stoplist records.
#
# Stoplist records (the file is private; its text is never echoed on errors):
#   word VALUE            VALUE as a whole word; [A-Za-z0-9_] is word, the rest is boundary
#   ci VALUE              the same, ignoring case
#   regex PERL_REGEX      a Perl regex, taken as written
#   allow VALUE REPO:PATH VALUE may appear in PATH of REPO; VALUE names another record
use strict;
use warnings;
use utf8;
use Encode qw(decode encode);
use Getopt::Long qw(GetOptionsFromArray);

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

sub fail { my ($msg) = @_; print STDERR "$msg\n"; exit 2 }

# Why decode at all: a Cyrillic stoplist value must compare and case-fold as
# text, and invalid bytes in a scanned file must not kill the scan.
sub dec { return decode('UTF-8', $_[0]) }

my @args = map { dec($_) } @ARGV;
my %o;
GetOptionsFromArray(\@args, \%o, 'patterns=s', 'stoplist=s', 'repo=s', 'redact', 'validate', 'help|h')
  or fail('error: bad arguments');
if ($o{help}) {
  open my $self, '<', $0 or fail('error: cannot read own header');
  <$self>;
  while (my $l = <$self>) { last unless $l =~ s/^# ?//; print $l }
  exit 0;
}
fail('error: unexpected argument') if @args;

# Read a file as UTF-8 lines without line endings; CRLF files arrive from
# pasted secrets and Windows editors, and a stray \r would end up in values.
sub read_lines {
  my ($file, $what) = @_;
  open my $fh, '<:raw', $file or fail("error: cannot read $what file");
  my @l;
  while (my $line = <$fh>) {
    $line = dec($line);
    $line =~ s/\r?\n\z//;
    $line =~ s/\r\z//;
    push @l, $line;
  }
  return @l;
}

# Compile quietly: perl's own warning and error text would quote the regex.
sub compile {
  my ($src, $flags) = @_;
  local $SIG{__WARN__} = sub { };
  my $re = eval { $flags eq 'a' ? qr/$src/a : qr/$src/ };
  return $re;
}

# A record that can match zero-length anywhere (`\b`, `^`, `(?=.)`) would hit
# every line, so probe a spread of shapes, not only the empty string.
my @PROBES = ('', ' ', 'a b', 'a.b/c-d_e', '123', 'Probe WORD-123 x', "\x{432} Probe\x{435} \x{438} WORD");
sub matches_empty {
  my ($re) = @_;
  for my $probe (@PROBES) {
    while ($probe =~ /$re/g) { return 1 if length($&) == 0 }
  }
  return 0;
}

# Returns ([records], error-message-or-undef). Errors name the record number
# and a reason only, never the record text.
sub load_stoplist {
  my ($file) = @_;
  my (@recs, %values);
  my $n = 0;
  for my $line (read_lines($file, 'stoplist')) {
    next if $line =~ /^\s*$/ || $line =~ /^\s*#/;
    $n++;
    my $err = sub { return (undef, "stoplist: record $n \x{2014} $_[0]") };
    $line =~ s/^\s+//;
    $line =~ s/\s+\z//;
    my ($kind, $rest) = $line =~ /^(\S+)(?:\s+(.*))?\z/s;
    $rest = '' unless defined $rest;
    my %r = (n => $n, kind => $kind);
    if ($kind eq 'allow') {
      my ($value, $where) = $rest =~ /^(.*?)\s*(\S+)\z/s;
      return $err->('allow needs a value and repo:path') unless defined $where && $where =~ /^[^:]+:.+/;
      return $err->('empty value') if !defined $value || $value eq '';
      @r{qw(value where)} = ($value, $where);
    } elsif ($kind eq 'word' || $kind eq 'ci' || $kind eq 'regex') {
      return $err->('empty value') if $rest eq '';
      $r{value} = $rest;
      my $re;
      if ($kind eq 'regex') {
        $re = compile($rest, 'a');
      } else {
        my $ci = $kind eq 'ci' ? '(?i)' : '';
        $re = compile($ci . '(?<![A-Za-z0-9_])' . quotemeta($rest) . '(?![A-Za-z0-9_])', 'a');
      }
      return $err->('invalid regex') unless defined $re;
      return $err->('matches the empty string') if matches_empty($re);
      $r{re} = $re;
      $values{$rest} = 1;
    } else {
      return $err->('unknown kind');
    }
    push @recs, \%r;
  }
  # allow lines may precede the record they name, so check after the pass.
  for my $r (@recs) {
    next unless $r->{kind} eq 'allow';
    return (undef, "stoplist: record $r->{n} \x{2014} allow refers to no record") unless $values{$r->{value}};
  }
  return (\@recs, undef);
}

my $recs = [];
if (defined $o{stoplist}) {
  my ($r, $e) = load_stoplist($o{stoplist});
  fail($e) if defined $e;
  $recs = $r;
}
if ($o{validate}) {
  fail('error: --validate needs --stoplist') unless defined $o{stoplist};
  exit 0;
}

fail('error: --patterns is required') unless defined $o{patterns};
fail('error: --repo is required') unless defined $o{repo};

my @rules;    # { id, re, value }
my $ln = 0;
for my $line (read_lines($o{patterns}, 'patterns')) {
  $ln++;
  next if $line =~ /^\s*$/ || $line =~ /^\s*#/;
  my $re = compile($line, '') or fail("patterns: line $ln \x{2014} invalid regex");
  push @rules, { id => "patterns#$ln", re => $re };
}
my %allowed;    # "value\0repo:path"
for my $r (@$recs) {
  if ($r->{kind} eq 'allow') { $allowed{"$r->{value}\0$r->{where}"} = 1; next }
  push @rules, { id => "stoplist#$r->{n}", re => $r->{re}, value => $r->{value}, stop => 1 };
}

# Every fragment of $text that a rule matches, as [rule, fragment]; stoplist
# rules are silenced by an allow for this repo and $path.
sub hits_in {
  my ($text, $path) = @_;
  my @h;
  for my $rule (@rules) {
    next if $rule->{stop} && $allowed{"$rule->{value}\0$o{repo}:$path"};
    while ($text =~ /$rule->{re}/g) { push @h, [$rule, $&] }
  }
  return @h;
}

# Under --redact the loc is printed in CI logs, and its file name can itself
# be a leak. Keep the non-path parts (commit/tag word, sha, line number) and
# blank out a path or tag name that hits a rule.
sub redact_loc {
  my ($loc, $path) = @_;
  my ($kind, $name, $mid, $line) = $loc =~ /^(?:(commit|tag) (\S+) )?(.*?)(:\d+)?\z/s;
  $line = '' unless defined $line;
  $mid = '<redacted path>' if hits_in($mid, $path);
  my $head = '';
  if (defined $kind) {
    $name = '<redacted>' if hits_in($name, $path);
    $head = "$kind $name ";
  }
  return "$head$mid$line";
}

binmode STDIN, ':raw';
my $hits = 0;
my $lineno = 0;
while (my $raw = <STDIN>) {
  $lineno++;
  $raw =~ s/\n\z//;
  my ($loc, $path, $text) = split /\t/, dec($raw), 3;
  fail("error: stream line $lineno is not <loc>TAB<path>TAB<text>") unless defined $text;
  my $shown = $o{redact} ? redact_loc($loc, $path) : $loc;
  for my $hit (hits_in($text, $path)) {
    $hits++;
    print $o{redact} ? "$shown $hit->[0]{id}\n" : "$shown $hit->[0]{id} $hit->[1]\n";
  }
}
exit($hits ? 1 : 0);
