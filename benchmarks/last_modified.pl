#!/usr/bin/perl

use strict;
use warnings;

use Benchmark qw(cmpthese timethese);
use File::Temp ();
use FindBin ();
use Getopt::Long qw(GetOptions);

use lib "$FindBin::Bin/../lib";

use Mojo::Date;
use Mojolicious;
use Test::Mojo;

my $dirs = 100;
my $files = 100;
my $iterations = 200;
my $help;

GetOptions(
	'dirs=i' => \$dirs,
	'files=i' => \$files,
	'iterations=i' => \$iterations,
	'help' => \$help,
) or usage(2);
usage(0) if $help;

die "--dirs must be positive\n" unless $dirs > 0;
die "--files must be positive\n" unless $files > 0;
die "--iterations must be positive\n" unless $iterations > 0;

print "Creating $dirs directories of $files templates (", $dirs * $files, " files)...\n";

my $tmp = File::Temp->newdir('mpb-bench-XXXXXX', TMPDIR => 1);
for my $d (1 .. $dirs) {
	my $dir = "$tmp/d$d";
	mkdir($dir) or die "Cannot create $dir: $!\n";
	for my $f (1 .. $files) {
		my $path = "$dir/t$f.html.ep";
		open(my $fh, '>', $path) or die "Cannot write $path: $!\n";
		print $fh "<p>$d/$f</p>\n";
		close($fh) or die "Cannot close $path: $!\n";
	}
}

my $epoch = time;
my $expected = Mojo::Date->new($epoch)->to_string;

my $scan_t = Test::Mojo->new(build_app(1));
my $epoch_t = Test::Mojo->new(build_app($epoch));
$scan_t->ua->transactor->compressed(0);
$epoch_t->ua->transactor->compressed(0);

my $scan = $scan_t->ua->get('/');
die "The scan request failed: ", $scan->res->code, "\n" unless $scan->res->code == 200;
die "The scan did not set Last-Modified\n" unless defined($scan->res->headers->last_modified);

my $explicit = $epoch_t->ua->get('/');
die "The epoch request failed: ", $explicit->res->code, "\n" unless $explicit->res->code == 200;
die "The explicit epoch was not used\n"
	unless $explicit->res->headers->last_modified eq $expected;

# Warm up the routes, renderers and user agents before timing.
$scan_t->ua->get('/')->res->code == 200 or die "Warm-up failed\n";
$epoch_t->ua->get('/')->res->code == 200 or die "Warm-up failed\n";

print "Timing $iterations iterations per variant...\n\n";

my $results = timethese($iterations, {
	'default scan' => sub { _get($scan_t, '/') },
	'explicit epoch' => sub { _get($epoch_t, '/') },
});

cmpthese($results);

my $scan_ms = 1000 * $results->{'default scan'}->cpu_a / $results->{'default scan'}->iters;
my $epoch_ms = 1000 * $results->{'explicit epoch'}->cpu_a / $results->{'explicit epoch'}->iters;
my $overhead = $scan_ms - $epoch_ms;
my $percent = $epoch_ms > 0 ? (100 * $overhead / $epoch_ms) : 0;

printf "\nDefault scan:   %.3f ms/request\n", $scan_ms;
printf "Explicit epoch: %.3f ms/request\n", $epoch_ms;
printf "Scan overhead:  %.3f ms/request (%.1f%%)\n", $overhead, $percent;
printf "Per tree entry: %.2f microseconds (including the %d directories)\n",
	1000 * $overhead / ($dirs * ($files + 1)), $dirs;

exit(0);

sub build_app {
	my $last_modified = shift;

	my $app = Mojolicious->new;
	$app->log->level('error');
	$app->renderer->paths(["$tmp"]);
	$app->plugin('Buffer',
		compress_content => 0,
		optimise_content => 0,
		generate_etag => 0,
		generate_304 => 0,
		last_modified => $last_modified,
	);
	$app->routes->get('/' => sub {
		my $c = shift;
		$c->render(text => 'ok');
	});

	return $app;
}

sub _get {
	my ($t, $path) = @_;

	my $tx = $t->ua->get($path);
	die "$path failed: ", $tx->res->code, "\n" unless $tx->res->code == 200;

	return;
}

sub usage {
	my $status = shift;

	print <<'USAGE';
Usage: benchmarks/last_modified.pl [options]

  --dirs N       Number of template directories (default 100)
  --files N      Number of templates per directory (default 100)
  --iterations N Iterations per variant (default 200)
  --help         Show this help

The default tree is 10,000 templates.  The script compares a request where
Last-Modified is the scan of that tree with the same request using an explicit
epoch, then prints the cost of the scan.
USAGE

	exit($status);
}
