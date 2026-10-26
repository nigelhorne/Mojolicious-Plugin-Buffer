use strict;
use warnings;

use Test::More;
use File::Temp ();
use Mojo::Date;
use Mojolicious;
use Test::Mojo;

{
	package TestCache;

	sub new { bless {data => {}, sets => 0}, shift }

	sub get { $_[0]->{data}{$_[1]} }

	sub set {
		my ($self, $key, $value, $duration) = @_;
		$self->{data}{$key} = $value;
		$self->{sets}++;
		return 1;
	}

	sub remove {
		my ($self, $key) = @_;
		delete $self->{data}{$key};
		return 1;
	}
}

sub write_file {
	my ($path, $content, $mtime) = @_;

	open(my $fh, '>', $path) or die "Cannot write $path: $!";
	print $fh $content;
	close($fh);
	utime($mtime, $mtime, $path) or die "Cannot set the mtime on $path: $!";

	return;
}

sub write_template {
	my ($path, $text, $mtime) = @_;

	return write_file($path, "<html><body><p>$text</p></body></html>\n", $mtime);
}

sub build_app {
	my ($dir, %options) = @_;

	my $app = Mojolicious->new;
	$app->log->level('error');
	$app->renderer->paths(["$dir"]);
	$app->plugin('Buffer', %options);
	$app->routes->get('/template' => sub {
		my $c = shift;
		return if $c->buffer_is_cached;
		$c->render(template => 'page');
	});

	return $app;
}

subtest 'the default Last-Modified follows template changes' => sub {
	my $dir = File::Temp->newdir('mpb-template-XXXXXX', TMPDIR => 1);
	my $template = "$dir/page.html.ep";
	my $fake_script = "$dir/app.pl";
	my $first = 2_000;
	my $second = $first + 60;
	write_file($fake_script, "1;\n", 1_000);
	write_template($template, 'first', $first);
	utime(900, 900, "$dir") or die "Cannot set the mtime on $dir: $!";

	local $0 = $fake_script;

	my $t = Test::Mojo->new(build_app($dir));
	$t->ua->transactor->compressed(0);

	$t->get_ok('/template')->status_is(200);
	my $lm = $t->tx->res->headers->last_modified;
	is($lm, Mojo::Date->new($first)->to_string, 'the newest template mtime is used');
	like($t->tx->res->body, qr/first/, 'the template was rendered');
	$t->get_ok('/template' => {'If-Modified-Since' => $lm})->status_is(304);

	write_template($template, 'second', $second);

	# A new app models a reload, so the renderer has not cached the old template
	my $t2 = Test::Mojo->new(build_app($dir));
	$t2->ua->transactor->compressed(0);
	$t2->get_ok('/template' => {'If-Modified-Since' => $lm})->status_is(200);
	is($t2->tx->res->headers->last_modified, Mojo::Date->new($second)->to_string,
		'the edited template moved Last-Modified');
	like($t2->tx->res->body, qr/second/, 'the edited template was rendered');
	$t2->get_ok('/template' => {'If-Modified-Since' => Mojo::Date->new($second)->to_string})->status_is(304);
};

subtest 'a template change invalidates the cached response' => sub {
	my $dir = File::Temp->newdir('mpb-template-cache-XXXXXX', TMPDIR => 1);
	my $template = "$dir/page.html.ep";
	my $fake_script = "$dir/app.pl";
	write_file($fake_script, "1;\n", 1_000);
	write_template($template, 'first', 2_000);
	utime(900, 900, "$dir") or die "Cannot set the mtime on $dir: $!";

	# Keep the application script older than the template, so only a
	# template-aware check can discard the entry below.
	local $0 = $fake_script;

	my $cache = TestCache->new;
	my $t = Test::Mojo->new(build_app($dir, cache => $cache));
	$t->ua->transactor->compressed(0);

	$t->get_ok('/template')->status_is(200)->header_is('X-Cache' => 'MISS');
	like($t->tx->res->body, qr/first/, 'the first response was built');
	$t->get_ok('/template')->status_is(200)->header_is('X-Cache' => 'HIT');
	is($cache->{sets}, 1, 'the first response was stored');

	my ($key) = keys %{$cache->{data}};
	$cache->{data}{$key}{created} = 1_500;

	write_template($template, 'second', 2_000);

	my $t2 = Test::Mojo->new(build_app($dir, cache => $cache));
	$t2->ua->transactor->compressed(0);
	$t2->get_ok('/template')->status_is(200)->header_is('X-Cache' => 'MISS');
	like($t2->tx->res->body, qr/second/, 'the edited template replaced the cached body');
	is($cache->{sets}, 2, 'the new response was stored');
};

done_testing();
