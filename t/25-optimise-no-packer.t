use strict;
use warnings;

use Test::More;
use Mojolicious;
use Test::Mojo;
use Mojolicious::Plugin::Buffer;

# Pretend HTML::Packer is not installed.  This is the check the plugin uses,
# so the rest of the response pipeline is the real one.
{
	no warnings 'redefine';
	my $real = \&Mojolicious::Plugin::Buffer::_module_available;
	*Mojolicious::Plugin::Buffer::_module_available = sub {
		my $name = shift;
		return 0 if $name eq 'HTML::Packer';
		return $real->($name);
	};
}

ok(!Mojolicious::Plugin::Buffer::_module_available('HTML::Packer'), 'HTML::Packer is treated as unavailable');

my $HTML = <<'HTML';
<html>
  <head>
    <title>  A  test  page  </title>
    <!-- keep this comment -->
    <style>
      .header { color: red; }
    </style>
  </head>
  <body>
    <div>   <p>Hello   World</p>   </div>
    <a href="__ORIGIN__/page">A page</a>
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
		(my $html = $HTML) =~ s/__ORIGIN__/$origin/g;
		$c->render(text => $html);
	});

	return $app;
}

subtest 'the whitespace routine still runs' => sub {
	my $app = build_app(optimise_content => 1);
	my $log = '';
	open(my $fh, '>', \$log) or die $!;
	$app->log->handle($fh);

	my $t = Test::Mojo->new($app);
	$t->ua->transactor->compressed(0);
	$t->get_ok('/opt')->status_is(200);

	my $body = $t->tx->res->body;
	cmp_ok(length($body), '<', length($HTML), 'the response is smaller');
	like($body, qr/<p>Hello World<\/p>/, 'white space is squashed');
	unlike($body, qr/\n\s*\n/, 'blank lines are removed');
	like($body, qr/keep this comment/, 'comments are left alone');
	like($body, qr{<a href="/page">}, 'same-site links are still rewritten');
	like($body, qr/var answer = 42/, 'JavaScript is preserved');
	is($t->tx->res->headers->content_length, length($body), 'Content-Length matches');
	unlike($log, qr/HTML::Packer failed/, 'no HTML::Packer error is logged');
};

subtest 'level 2 does not fail without HTML::Packer' => sub {
	my $t = Test::Mojo->new(build_app(optimise_content => 2));
	$t->ua->transactor->compressed(0);
	$t->get_ok('/opt')->status_is(200);

	my $body = $t->tx->res->body;
	like($body, qr/<p>Hello World<\/p>/, 'white space is still squashed');
	like($body, qr/keep this comment/, 'comments are still left alone');
};

done_testing();
