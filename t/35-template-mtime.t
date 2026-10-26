use strict;
use warnings;

use Test::More;
use File::Temp ();
use Mojo::Date;
use Mojolicious;
use Test::Mojo;

{
	package TestCache;

	sub new { bless {data => {}, sets => 0, gets => 0, durations => []}, shift }

	sub get {
		my ($self, $key) = @_;
		$self->{gets}++;
		return $self->{data}{$key};
	}

	sub set {
		my ($self, $key, $value, $duration) = @_;
		$self->{data}{$key} = $value;
		push @{$self->{durations}}, $duration;
		$self->{sets}++;
		return 1;
	}

	sub remove {
		my ($self, $key) = @_;
		delete $self->{data}{$key};
		return 1;
	}
}

{
	package BrokenMtimeCache;

	sub new { bless {}, shift }

	sub get { die "mtime get failed\n" }

	sub set { die "mtime set failed\n" }
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

sub set_mtime {
	my ($path, $mtime) = @_;

	utime($mtime, $mtime, $path) or die "Cannot set the mtime on $path: $!";

	return;
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

subtest 'adding a template directory moves Last-Modified' => sub {
	my $dir = File::Temp->newdir('mpb-template-add-XXXXXX', TMPDIR => 1);
	my $template = "$dir/page.html.ep";
	my $fake_script = "$dir/app.pl";
	my $first = 2_000;
	my $added = $first + 120;
	write_file($fake_script, "1;\n", 1_000);
	write_template($template, 'first', $first);
	set_mtime($dir, 900);

	local $0 = $fake_script;

	my $t = Test::Mojo->new(build_app($dir));
	$t->ua->transactor->compressed(0);
	$t->get_ok('/template')->status_is(200);
	my $lm = $t->tx->res->headers->last_modified;
	is($lm, Mojo::Date->new($first)->to_string, 'the initial validator comes from the template');
	$t->get_ok('/template' => {'If-Modified-Since' => $lm})->status_is(304);

	my $sub = "$dir/sub";
	mkdir($sub) or die "Cannot create $sub: $!";
	write_template("$sub/extra.html.ep", 'extra', $first);

	# Adding the directory changes its mtime and the mtime of its parent;
	# the file inside deliberately stays older than both.
	set_mtime($sub, $added);
	set_mtime($dir, $added);

	my $t2 = Test::Mojo->new(build_app($dir));
	$t2->ua->transactor->compressed(0);
	$t2->get_ok('/template' => {'If-Modified-Since' => $lm})->status_is(200);
	is($t2->tx->res->headers->last_modified, Mojo::Date->new($added)->to_string,
		'the new directory moved Last-Modified');
};

subtest 'deleting a template directory moves Last-Modified' => sub {
	my $dir = File::Temp->newdir('mpb-template-del-XXXXXX', TMPDIR => 1);
	my $template = "$dir/page.html.ep";
	my $fake_script = "$dir/app.pl";
	my $first = 2_000;
	my $sub_mtime = $first + 100;
	my $removed = $first + 220;
	write_file($fake_script, "1;\n", 1_000);
	write_template($template, 'first', $first);

	my $sub = "$dir/sub";
	mkdir($sub) or die "Cannot create $sub: $!";
	write_template("$sub/extra.html.ep", 'extra', $sub_mtime);
	set_mtime($sub, $sub_mtime);
	set_mtime($dir, 900);

	local $0 = $fake_script;

	my $t = Test::Mojo->new(build_app($dir));
	$t->ua->transactor->compressed(0);
	$t->get_ok('/template')->status_is(200);
	my $lm = $t->tx->res->headers->last_modified;
	is($lm, Mojo::Date->new($sub_mtime)->to_string, 'the directory is part of the initial validator');

	unlink("$sub/extra.html.ep") or die "Cannot remove the extra template: $!";
	rmdir($sub) or die "Cannot remove $sub: $!";
	set_mtime($dir, $removed);

	my $t2 = Test::Mojo->new(build_app($dir));
	$t2->ua->transactor->compressed(0);
	$t2->get_ok('/template' => {'If-Modified-Since' => $lm})->status_is(200);
	is($t2->tx->res->headers->last_modified, Mojo::Date->new($removed)->to_string,
		'the deletion moved Last-Modified');
};

subtest 'symlinked template directories are followed without looping' => sub {
	my $dir = File::Temp->newdir('mpb-template-link-XXXXXX', TMPDIR => 1);
	my $outside = File::Temp->newdir('mpb-template-outside-XXXXXX', TMPDIR => 1);
	my $template = "$dir/page.html.ep";
	my $fake_script = "$dir/app.pl";
	my $first = 2_000;
	my $linked = $first + 400;
	write_file($fake_script, "1;\n", 1_000);
	write_template($template, 'first', $first);
	write_template("$outside/linked.html.ep", 'linked', $linked);

	my $ok = eval {
		symlink("$outside", "$dir/linked") or die "Cannot link $outside: $!";
		symlink($dir, "$dir/loop") or die "Cannot create a loop symlink: $!";
		1;
	};
	plan skip_all => "symlinks are unavailable: $@" unless $ok;

	set_mtime($outside, 2_300);
	set_mtime($dir, 900);

	local $0 = $fake_script;

	my $t = Test::Mojo->new(build_app($dir));
	$t->ua->transactor->compressed(0);

	my $completed = eval {
		local $SIG{ALRM} = sub { die "the symlink loop did not terminate\n" };
		alarm(5);
		$t->get_ok('/template')->status_is(200);
		alarm(0);
		1;
	};
	alarm(0);
	ok($completed, 'the request finishes even with a symlink loop') or diag($@);

	is($t->tx->res->headers->last_modified, Mojo::Date->new($linked)->to_string,
		'a newer template behind the symlink is seen')
		if $completed;
};

subtest 'the template mtime scan can be cached' => sub {
	my $dir = File::Temp->newdir('mpb-template-mtime-cache-XXXXXX', TMPDIR => 1);
	my $template = "$dir/page.html.ep";
	my $fake_script = "$dir/app.pl";
	my $first = 2_000;
	my $second = $first + 100;
	write_file($fake_script, "1;\n", 1_000);
	write_template($template, 'first', $first);
	set_mtime($dir, 900);

	local $0 = $fake_script;

	my $cache = TestCache->new;
	my $t = Test::Mojo->new(build_app($dir,
		template_mtime_cache => $cache,
		template_mtime_cache_duration => 60,
	));
	$t->ua->transactor->compressed(0);

	$t->get_ok('/template')->status_is(200);
	is($t->tx->res->headers->last_modified, Mojo::Date->new($first)->to_string,
		'the first request scanned the template tree');
	is($cache->{gets}, 1, 'the request read the cache once');
	is($cache->{sets}, 1, 'the scan was cached');
	is_deeply($cache->{durations}, [60], 'the configured duration was used');

	# The cached value deliberately hides the edit until the entry expires.
	# If the scan still ran, this request would see $second.
	write_template($template, 'second', $second);
	set_mtime($dir, 900);

	$t->get_ok('/template')->status_is(200);
	is($t->tx->res->headers->last_modified, Mojo::Date->new($first)->to_string,
		'a cache hit reuses the mtime without scanning');
	is($cache->{gets}, 2, 'each request reads the cache once');
	is($cache->{sets}, 1, 'a cache hit does not store anything');

	# Model expiry by dropping the entry
	my ($key) = keys %{$cache->{data}};
	ok(defined($key), 'the mtime was stored under a key') or return;
	delete $cache->{data}{$key};

	$t->get_ok('/template')->status_is(200);
	is($t->tx->res->headers->last_modified, Mojo::Date->new($second)->to_string,
		'a cache miss scans again and sees the edited template');
	is($cache->{gets}, 3, 'the miss was looked up');
	is($cache->{sets}, 2, 'the new scan was cached');
};

subtest 'a CHI cache can hold the template mtime' => sub {
	eval { require CHI; 1 } or plan skip_all => 'CHI is not installed';

	my $dir = File::Temp->newdir('mpb-template-chi-XXXXXX', TMPDIR => 1);
	my $template = "$dir/page.html.ep";
	my $fake_script = "$dir/app.pl";
	my $first = 2_000;
	my $second = $first + 100;
	write_file($fake_script, "1;\n", 1_000);
	write_template($template, 'first', $first);
	set_mtime($dir, 900);

	local $0 = $fake_script;

	my $cache = CHI->new(driver => 'Memory', datastore => {});
	my $t = Test::Mojo->new(build_app($dir,
		template_mtime_cache => $cache,
		template_mtime_cache_duration => 60,
	));
	$t->ua->transactor->compressed(0);

	$t->get_ok('/template')->status_is(200);
	is($t->tx->res->headers->last_modified, Mojo::Date->new($first)->to_string,
		'CHI stores the first scan');

	write_template($template, 'second', $second);
	set_mtime($dir, 900);

	$t->get_ok('/template')->status_is(200);
	is($t->tx->res->headers->last_modified, Mojo::Date->new($first)->to_string,
		'CHI serves the cached mtime');

	$cache->clear;
	$t->get_ok('/template')->status_is(200);
	is($t->tx->res->headers->last_modified, Mojo::Date->new($second)->to_string,
		'clearing CHI causes a fresh scan');
};

subtest 'cached mtimes do not leak between template trees' => sub {
	my $first_dir = File::Temp->newdir('mpb-template-tree-one-XXXXXX', TMPDIR => 1);
	my $second_dir = File::Temp->newdir('mpb-template-tree-two-XXXXXX', TMPDIR => 1);
	my $fake_script = "$first_dir/app.pl";
	my $first = 2_000;
	my $second = 3_000;
	write_file($fake_script, "1;\n", 1_000);
	write_template("$first_dir/page.html.ep", 'first', $first);
	write_template("$second_dir/page.html.ep", 'second', $second);
	set_mtime($first_dir, 900);
	set_mtime($second_dir, 900);

	local $0 = $fake_script;

	my $cache = TestCache->new;
	my $first_t = Test::Mojo->new(build_app($first_dir, template_mtime_cache => $cache));
	$first_t->ua->transactor->compressed(0);
	$first_t->get_ok('/template')->status_is(200);
	is($first_t->tx->res->headers->last_modified, Mojo::Date->new($first)->to_string,
		'the first tree has its own mtime');

	my $second_t = Test::Mojo->new(build_app($second_dir, template_mtime_cache => $cache));
	$second_t->ua->transactor->compressed(0);
	$second_t->get_ok('/template')->status_is(200);
	is($second_t->tx->res->headers->last_modified, Mojo::Date->new($second)->to_string,
		'a second tree does not reuse the first tree\'s cached mtime');
	is($cache->{sets}, 2, 'each tree was cached separately');
};

subtest 'a failing template mtime cache falls back to scanning' => sub {
	my $dir = File::Temp->newdir('mpb-template-broken-cache-XXXXXX', TMPDIR => 1);
	my $template = "$dir/page.html.ep";
	my $fake_script = "$dir/app.pl";
	my $first = 2_000;
	write_file($fake_script, "1;\n", 1_000);
	write_template($template, 'first', $first);
	set_mtime($dir, 900);

	local $0 = $fake_script;

	my $t = Test::Mojo->new(build_app($dir, template_mtime_cache => BrokenMtimeCache->new));
	$t->ua->transactor->compressed(0);

	$t->get_ok('/template')->status_is(200);
	like($t->tx->res->body, qr/first/, 'the response is still rendered');
	is($t->tx->res->headers->last_modified, Mojo::Date->new($first)->to_string,
		'a broken cache does not stop the scan');
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
