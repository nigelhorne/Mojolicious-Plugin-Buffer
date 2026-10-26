use strict;
use warnings;

use Test::More;
use Mojolicious;
use Test::Mojo;

my $HAVE_PACKER = eval { require HTML::Packer; 1 } ? 1 : 0;

my $HTML = <<'HTML';
<html>
  <head>
    <title>  A  test  page  </title>
    <!-- remove this comment -->
    <style>
      .header { color: red; }
    </style>
  </head>
  <body>
    <div>   <p>Hello   World</p>   </div>
    <a href="__ORIGIN__/page">A page</a>
    <a href="__ORIGIN__/search?q=perl">A search</a>
    <a href="__PATH__?q=perl">This page again</a>
    <img src="__ORIGIN__/logo.png">
    <script>
      var answer = 42;
    </script>
  </body>
</html>
HTML

sub build_app {
	my (%options) = @_;

	my $app = Mojolicious->new;
	$app->log->level('error');
	$app->plugin('Buffer', %options);

	$app->routes->get('/opt' => sub {
		my $c = shift;
		my $url = $c->req->url->to_abs;
		my $origin = $url->scheme . '://' . ($url->host_port // $url->host);
		my $path = $url->path->to_string;
		(my $html = $HTML) =~ s/__ORIGIN__/$origin/g;
		$html =~ s/__PATH__/$path/g;
		$c->render(text => $html);
	});
	$app->routes->get('/plain' => sub {
		my $c = shift;
		$c->render(data => $HTML, format => 'txt');
	});
	$app->routes->get('/off' => sub {
		my $c = shift;
		$c->stash(buffer => {optimise_content => 0});
		$c->render(text => $HTML);
	});

	return $app;
}

my $app = build_app(optimise_content => 1);
my $log = '';
open(my $log_fh, '>', \$log) or die $!;
$app->log->handle($log_fh);

my $t = Test::Mojo->new($app);
$t->ua->transactor->compressed(0);

subtest 'HTML is optimised' => sub {
	$t->get_ok('/opt')->status_is(200);

	my $body = $t->tx->res->body;
	cmp_ok(length($body), '<', length($HTML), 'body is smaller than the original');
	if ($HAVE_PACKER) {
		unlike($body, qr/remove this comment/, 'comments are removed');
	} else {
		like($body, qr/remove this comment/, 'comments are kept without HTML::Packer');
		unlike($log, qr/HTML::Packer failed/, 'no HTML::Packer failure was logged');
	}
	unlike($body, qr/\n\s*\n/, 'blank lines are removed');
	like($body, qr{<a href="/page">}, 'absolute link to this site became root-relative');
	like($body, qr{<a href="/search\?q=perl">}, 'absolute link with a query became root-relative');
	like($body, qr{<a href="\?q=perl">}, 'link to the current page became a query-only link');
	unlike($body, qr{<a href="/opt\?}, 'the current page path was dropped');
	like($body, qr{<img src="/logo\.png">}, 'absolute image link became root-relative');
	like($body, qr/var answer = 42/, 'JavaScript is preserved');
	is($t->tx->res->headers->content_length, length($body), 'Content-Length matches the optimised body');
};

subtest 'only HTML is optimised' => sub {
	$t->get_ok('/plain')->status_is(200);
	is($t->tx->res->body, $HTML, 'text/plain is untouched');
};

subtest 'optimise_content can be turned off per response' => sub {
	$t->get_ok('/off')->status_is(200);
	is($t->tx->res->body, $HTML, 'body is untouched');
};

subtest 'optimisation is off by default' => sub {
	my $default = Test::Mojo->new(build_app());
	$default->ua->transactor->compressed(0);
	$default->get_ok('/opt')->status_is(200);
	like($default->tx->res->body, qr/remove this comment/, 'comments are kept');
};

subtest 'level 2 works without HTML::Packer' => sub {
	plan skip_all => 'HTML::Packer is installed' if $HAVE_PACKER;

	my $app = build_app(optimise_content => 2);
	my $log = '';
	open(my $log_fh, '>', \$log) or die $!;
	$app->log->handle($log_fh);

	my $t = Test::Mojo->new($app);
	$t->ua->transactor->compressed(0);
	$t->get_ok('/opt')->status_is(200);

	my $body = $t->tx->res->body;
	like($body, qr/<p>Hello World<\/p>/, 'white space is still squashed');
	like($body, qr/remove this comment/, 'comments are still left alone');
	like($body, qr/var answer = 42/, 'JavaScript is still preserved');
	unlike($log, qr/HTML::Packer failed/, 'no HTML::Packer failure is logged');
};

{
	package TestBuffer::Controller::Optimised;
	use Mojo::Base 'Mojolicious::Controller';

	has buffer_optimise_content => 1;

	sub page { shift->render(text => '<div>   <p>Hello   World</p>   </div>') }
}

{
	package TestBuffer::Controller::PlainPage;
	use Mojo::Base 'Mojolicious::Controller';

	sub page { shift->render(text => '<div>   <p>Hello   World</p>   </div>') }
}

subtest 'optimise_content can be declared for a group of pages' => sub {
	my $page     = '<div>   <p>Hello   World</p>   </div>';
	my $squashed = qr{<div><p>Hello World</p></div>};
	my $original = qr{   <p>Hello   World</p>   };

	my $group_app = Mojolicious->new;
	$group_app->log->level('error');
	$group_app->plugin('Buffer');

	my $r = $group_app->routes;
	$r->get('/route' => {optimise_content => 1} => sub { shift->render(text => $page) });
	$r->get('/plain' => sub { shift->render(text => $page) });

	my $docs = $r->under('/docs')->to(optimise_content => 1);
	$docs->get('/one' => sub { shift->render(text => $page) });
	$docs->get('/raw' => {optimise_content => 0} => sub { shift->render(text => $page) });
	$docs->get('/override' => sub {
		my $c = shift;
		$c->stash(buffer => {optimise_content => 0});
		$c->render(text => $page);
	});

	$r->namespaces(['TestBuffer::Controller']);
	$r->get('/static')->to('Optimised#page');
	$r->get('/volatile')->to('PlainPage#page');

	my $group = Test::Mojo->new($group_app);
	$group->ua->transactor->compressed(0);

	$group->get_ok('/route')->status_is(200);
	like($group->tx->res->body, $squashed, 'a route default optimises that route');

	$group->get_ok('/docs/one')->status_is(200);
	like($group->tx->res->body, $squashed, 'an under route optimises everything below it');

	$group->get_ok('/static')->status_is(200);
	like($group->tx->res->body, $squashed, 'a controller declaration optimises its namespace');

	$group->get_ok('/plain')->status_is(200);
	like($group->tx->res->body, $original, 'a page outside the group is untouched');

	$group->get_ok('/volatile')->status_is(200);
	like($group->tx->res->body, $original, 'a controller without the declaration is untouched');

	$group->get_ok('/docs/raw')->status_is(200);
	like($group->tx->res->body, $original, 'a route default of 0 opts one page out');

	$group->get_ok('/docs/override')->status_is(200);
	like($group->tx->res->body, $original, 'the buffer stash overrides the group');
};

done_testing();
