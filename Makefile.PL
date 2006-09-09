use ExtUtils::MakeMaker;

WriteMakefile(
			  'NAME'	=> 'POE::Component::Server::Ident',
			  'PREREQ_PM' => {
							  'warnings' => 0,
							  'POE'    => 0.06_07,
							  'Carp'   => 0,
							  'Socket' => 0,
							 },
			  'VERSION_FROM' => 'lib/POE/Component/Server/Ident.pm',
			  'dist' => { 'COMPRESS' => 'gzip --best' },
			 );
