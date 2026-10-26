use strict;
use warnings;
use ExtUtils::MakeMaker 6.64;	# 6.64 for TEST_REQUIRES

my %prereq_pm = (
	'autodie' => 0,
	'Carp' => 0,
	'Exporter' => 0,
	'Fcntl' => 0,
	'File::Path' => '2.07',	# 2.07 for make_path() and its error option
	'File::Spec' => 0,
	'IPC::System::Simple' => 0,	# needed by use autodie qw(:all)
	'Mojolicious' => '9.00',
	'Params::Get' => '0.17',
	'Params::Validate::Strict' => '0.41',
	'Readonly' => '2.00',
	'Return::Set' => '0.05',
	'Scalar::Util' => 0,
	'Sub::Private' => '0.07',	# 0.07 for per-package enforce mode
	'Sub::Protected' => '0.03',
	'Time::HiRes' => 0,
	'version' => 0,
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
		'Digest::MD5' => 0,
		'Encode' => 0,
		'Errno' => 0,
		'File::Temp' => 0,
		'Mojo::Base' => 0,
		'POSIX' => 0,
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
			test => {
				recommends => {
					# t/locales.t resolves client addresses with it when present
					'IP::Country::Fast' => 0,
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
