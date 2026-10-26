use strict;
use warnings;

use Test::More;
use Digest::MD5 qw(md5_hex);
use Mojolicious;
use Mojo::Date;
use Test::Mojo;

my $LONG = '<p>' . ('The quick brown fox jumps over the lazy dog. ' x 10) . '</p>';

sub build_app {
	my (%options) = @_;

	my $app = Mojolicious->new;
	$app->log->level('error');
	$app->plugin('Buffer', %options);
	$app->routes->get('/' => sub {
		my $c = shift;
		$c->render(text => $LONG);
	});

	return $app;
}

my $t = Test::Mojo->new(build_app());
$t->ua->transactor->compressed(0);

my $identity_etag = '"' . md5_hex($LONG) . '"';

subtest 'ETag is generated' => sub {
	$t->get_ok('/')->status_is(200);
	$t->header_is(ETag => $identity_etag);
	is($t->tx->res->headers->etag, $identity_etag, 'tag is the MD5 of the body');
};

subtest 'If-None-Match' => sub {
	$t->get_ok('/' => {'If-None-Match' => $identity_etag});
	$t->status_is(304);
	$t->header_is(ETag => $identity_etag);
	is($t->tx->res->body, '', '304 has no body');

	$t->get_ok('/' => {'If-None-Match' => 'W/' . $identity_etag})->status_is(304);
	$t->get_ok('/' => {'If-None-Match' => '*'})->status_is(304);
	$t->get_ok('/' => {'If-None-Match' => '"not the tag"'})->status_is(200);
	$t->get_ok('/' => {'If-None-Match' => "$identity_etag, \"another\""})->status_is(304);
};

subtest 'content codings have their own ETags' => sub {
	$t->get_ok('/' => {'Accept-Encoding' => 'gzip'})->status_is(200);
	my $gzip_etag = $t->tx->res->headers->etag;
	isnt($gzip_etag, $identity_etag, 'gzip and identity representations differ');

	$t->get_ok('/' => {'Accept-Encoding' => 'gzip', 'If-None-Match' => $gzip_etag})->status_is(304);

	# The identity tag must not match the gzip representation
	$t->get_ok('/' => {'Accept-Encoding' => 'gzip', 'If-None-Match' => $identity_etag})->status_is(200);
};

subtest 'generate_etag can be turned off' => sub {
	my $no_etag = Test::Mojo->new(build_app(generate_etag => 0));
	$no_etag->ua->transactor->compressed(0);
	$no_etag->get_ok('/')->status_is(200);
	ok(!defined($no_etag->tx->res->headers->etag), 'no ETag');
	$no_etag->get_ok('/' => {'If-None-Match' => $identity_etag})->status_is(200);

	# Last-Modified still answers If-Modified-Since, but If-None-Match wins
	my $lm = Mojo::Date->new((stat($0))[9])->to_string;
	$no_etag->get_ok('/')->status_is(200);
	$no_etag->header_is('Last-Modified' => $lm);
	$no_etag->get_ok('/' => {'If-Modified-Since' => $lm})->status_is(304);
	$no_etag->get_ok('/' => {'If-Modified-Since' => $lm, 'If-None-Match' => '"anything"'})->status_is(200);
};

subtest 'generate_304 can be turned off' => sub {
	my $no_304 = Test::Mojo->new(build_app(generate_304 => 0));
	$no_304->ua->transactor->compressed(0);
	$no_304->get_ok('/')->status_is(200);
	$no_304->header_is(ETag => $identity_etag);
	$no_304->get_ok('/' => {'If-None-Match' => $identity_etag})->status_is(200);
	is($no_304->tx->res->body, $LONG, 'body is still sent');
};

subtest 'Last-Modified' => sub {
	my $modified = 1700000000;
	my $lm = Mojo::Date->new($modified)->to_string;
	my $dated = Test::Mojo->new(build_app(last_modified => $modified));
	$dated->ua->transactor->compressed(0);

	$dated->get_ok('/')->status_is(200);
	$dated->header_is('Last-Modified' => $lm);

	$dated->get_ok('/' => {'If-Modified-Since' => $lm})->status_is(304);
	$dated->get_ok('/' => {'If-Modified-Since' => Mojo::Date->new($modified - 3600)->to_string})->status_is(200);
	$dated->get_ok('/' => {'If-Modified-Since' => 'not a date'})->status_is(200);

	# If-None-Match takes precedence over If-Modified-Since
	$dated->get_ok('/' => {'If-Modified-Since' => $lm, 'If-None-Match' => '"wrong"'})->status_is(200);
	$dated->get_ok('/' => {'If-Modified-Since' => Mojo::Date->new($modified - 3600)->to_string,
		'If-None-Match' => $identity_etag})->status_is(304);
};

subtest 'Last-Modified is on by default' => sub {
	my $modified = (stat($0))[9];
	my $lm = Mojo::Date->new($modified)->to_string;

	$t->get_ok('/')->status_is(200);
	$t->header_is('Last-Modified' => $lm);

	$t->get_ok('/' => {'If-Modified-Since' => $lm})->status_is(304);
	$t->get_ok('/' => {'If-Modified-Since' => Mojo::Date->new($modified - 3600)->to_string})->status_is(200);
	$t->get_ok('/' => {'If-Modified-Since' => 'not a date'})->status_is(200);

	# The ETag still takes precedence over a matching If-Modified-Since
	$t->get_ok('/' => {'If-Modified-Since' => $lm, 'If-None-Match' => '"wrong"'})->status_is(200);
	$t->get_ok('/' => {'If-Modified-Since' => Mojo::Date->new($modified - 3600)->to_string,
		'If-None-Match' => $identity_etag})->status_is(304);
};

subtest 'Last-Modified can be turned off' => sub {
	my $off = Test::Mojo->new(build_app(last_modified => 0));
	$off->ua->transactor->compressed(0);
	$off->get_ok('/')->status_is(200);
	ok(!defined($off->tx->res->headers->last_modified), 'no Last-Modified header');
	$off->get_ok('/' => {'If-Modified-Since' => Mojo::Date->new(time + 3600)->to_string})->status_is(200);
};

subtest 'conditional requests are only for successful GET and HEAD' => sub {
	$t->get_ok('/missing')->status_is(404);
	ok(!defined($t->tx->res->headers->etag), 'no ETag on an error page');
};

subtest 'HEAD carries the headers of the matching GET' => sub {
	$t->get_ok('/' => {'Accept-Encoding' => 'gzip'})->status_is(200);
	my $length = $t->tx->res->headers->content_length;
	my $etag = $t->tx->res->headers->etag;

	$t->head_ok('/' => {'Accept-Encoding' => 'gzip'})->status_is(200);
	$t->header_is('Content-Length' => $length);
	$t->header_is(ETag => $etag);
	is($t->tx->res->body, '', 'HEAD has no body');
};

done_testing();
