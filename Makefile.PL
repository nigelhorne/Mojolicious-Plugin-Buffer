use strict;
use warnings;
use ExtUtils::MakeMaker 6.64;	# 6.64 for TEST_REQUIRES

my %prereq_pm = (
	'Carp' => 0,
	'Encode' => 0,
	'Mojolicious' => '9.00',
);

my $dist = {
	COMPRESS => 'gzip -9f',
	SUFFIX => 'gz',
};

if($^O eq 'darwin') {
	$dist->{'TAR'} = 'gtar';
}

WriteMakefile(
	NAME	=> 'Mojolicious::Plugin::Buffer',
	AUTHOR	=> q{Nigel Horne <njh@bandsman.co.uk>},
	VERSION_FROM		=> 'lib/Mojolicious/Plugin/Buffer.pm',
	ABSTRACT_FROM		=> 'lib/Mojolicious/Plugin/Buffer.pm',
	((defined($ExtUtils::MakeMaker::VERSION) &&
	 ($ExtUtils::MakeMaker::VERSION >= 6.3002))
			? ('LICENSE'=> 'GPL')
			: ()),
	PL_FILES	=> {},
	TEST_REQUIRES => {
		'Mojo::Base' => 0,
		'Test::More' => 0,
		'Test::Without::Module' => 0,
	},
	PREREQ_PM => \%prereq_pm,
	clean => { FILES => 'Mojolicious-Plugin-Buffer-*' },
	dist => $dist,
	META_MERGE		=> {
		'meta-spec' => { version => 2 },
		prereqs => {
			runtime => {
				recommends => {
					# Optional, checked for at runtime
					'CHI' => 0,
					'HTML::Packer' => 0,
					'IO::Compress::Brotli' => 0,
					'Compress::Zstd' => 0,
				},
			},
		},
		resources => {
			repository => {
				type => 'git',
				url => 'git://github.com/nigelhorne/Mojolicious-Plugin-Buffer.git',
				web => 'https://github.com/nigelhorne/Mojolicious-Plugin-Buffer',
			}, bugtracker => {
				web => 'https://github.com/nigelhorne/Mojolicious-Plugin-Buffer/issues',
				url => 'https://github.com/nigelhorne/Mojolicious-Plugin-Buffer/issues',
				mailto => 'bug-Mojolicious-Plugin-Buffer@rt.cpan.org'
			}
		},
	},
	MIN_PERL_VERSION	=> '5.16.0',
);
