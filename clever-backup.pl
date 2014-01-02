#!perl

$|=1;
use strict;
use subs qw/confess debug verbose/;
use warnings;

use Archive::Tar::Stream;
use Carp qw/longmess cluck confess/;
use Carp::Source::Always;
use Cwd;
use Data::Dumper;
use File::Copy;
use File::Find;
use File::Slurp;
use File::Spec::Functions qw/catfile/;
use File::Temp qw/ tempdir tempfile/;
use Getopt::Long qw/:config bundling/;
use IO::Scalar;
use MIME::Base64 ();
use IPC::Open3;
use POSIX qw/mkfifo :sys_wait_h/;
use Time::HiRes qw/time/;

no warnings 'redefine';	# for confess

my $original = cwd;
sub confess{ 
	chdir $original; 
	Carp::confess @_; 
};

my $start = time;
my $params = { 
	'sourceDirectories' 	=> ['/etc','/var'],
	'excludes'		=> ['/var/cache','/var/lib/dpkg'],
	'fail-on-missing-package-source' => 0,
	'no-apt-clone'		=> 1,
	'outputfile'		=> '',
	
	'compression'		=> 'gzip',
	'compressionCommand'	=> undef,
	'compressionLevel'	=> 6,
	
	'debug' 		=> 0, 
	'dryrun' 		=> 0,
	'print-options'		=> 0,
	'quiet'			=> 0,
	'verbose'		=> 0,
};

&parseOptionsAndGiveHelp($params);

my $file_to_package_map = &populateFileToPackageMap($params->{'sourceDirectories'},$params->{'excludes'});
my $filesInNoPackageList = &findFilesToBeBackedUpBecauseInNoPackage($params->{'sourceDirectories'},$params->{'excludes'});
my $changed_files_map = &findChangedFiles($params->{'sourceDirectories'},$params->{'excludes'}, $file_to_package_map);
my $diffs = &createDiffOfFiles($changed_files_map->{'changed'},$file_to_package_map);

&createBackupFile($filesInNoPackageList,$diffs,$changed_files_map->{'missing'});

verbose 'duration '. ( time - $start ) . "ms\n";
<STDIN>;

# ---- subs -----

sub createBackupFile{
	confess "need 3 params " if (scalar(@_) != 3);
	
	my $filesInNoPackageList 	= shift || confess "need files in no package";
	my $diffs 			= shift || confess "need diffs";
	my $missingFiles 		= shift || confess "need missing files";
	
	#~ chdir $original;
	
	verbose "creating backup file";
	
	my $tar = Archive::Tar::Stream->new(outfh => &getOutFileHandle());
	
	&addReadme(\$tar);
	&addChangedFiles(\$tar,$diffs);
	&addMissingFiles(\$tar,$missingFiles);
	&addFilesInNoPackage(\$tar,$filesInNoPackageList);
	
	verbose "skipping apt-clone" 	if ( $params->{'no-apt-clone'});
	&addAptClone(\$tar) 		if (!$params->{'no-apt-clone'});
	
	$tar->FinishTar();
	
	sub addAptClone{
		my $tar = shift || confess "need tar filehandle";
			
		
		my $basename = "clone";
		my $name = $basename.".apt-clone.tar.gz";
		my $tempdir = tempdir(CLEANUP=>0,UNLINK=>0);
		my $fullname = catfile($tempdir,$name);

		verbose "doing apt-clone";
		
		verbose "executing apt-clone\n";
		my $currentWD = cwd;
		chdir $tempdir;
			
		debug "changed into $tempdir";
		&execute("apt-clone clone --with-dpkg-status --with-dpkg-repack ".$basename);
		debug "finished apt-clone";
		
		chdir $currentWD;
		
		open my $fh,"<$fullname" || confess "could not read $fullname: $^E";
		$$tar->AddFile($name,-s $fh, $fh);
		close($fh);
		debug "Done";
	}
	
	sub addChangedFiles{
		my $tar = shift || confess "need tar filehandle";
		my $diffs = shift || confess "need diffs";
		
		verbose "adding diffs to archive";
		
		my $dirForChangedFiles = 'changed';
		$$tar->AddLink($dirForChangedFiles,$dirForChangedFiles,('typeflag'=>5));
		
		grep{
			while (my ($file, $metadata) = each %{$_}) {
				my $path = $dirForChangedFiles."".$file;
								
				debug "adding $file as $path";
				
				open my $fh, "<$file" || confess "could not open $file";
				$$tar->AddFile($path,-s $fh,$fh);
				close($fh);
				
				&__addTextAsFile($tar,$path.".__diff__",\$metadata->{'data'});
				
				my $info;
				$info .= "type \t ".$metadata->{'type'}."\n";
				$info .= "comment\t ".$metadata->{'comment'}."\n";
				&__addTextAsFile($tar,$path.".__info__", \$info);
				
			}
		}@{$diffs};
	}
	
	sub addMissingFiles{
		my $tar 		= shift || confess "need tar filehandle";
		my $missingFiles 	= shift || confess "need diffs";
		
		verbose "adding missing files to archive";
		
		
		my $dirForMissingFiles = 'missing';
		$$tar->AddLink($dirForMissingFiles,$dirForMissingFiles,('typeflag'=>5));
		
		grep{
			my $path = $dirForMissingFiles."".$_;
			debug "adding $_ as $path";
			$$tar->AddLink($path,$_);
		}@{$missingFiles };
	}
	
	sub addReadme{
		my $tar = shift || confess "need tar filehandle";
		
		my $text = <<EndOfReadme;

some information on these entries:
--------------------------------------------

- no_package		files, which are not originally from any package installed on the system
- changed		files, which are changed (contains : full version, diff and info parts )
- missing		files, which are missing 

EndOfReadme
		&__addTextAsFile($tar,"README",\$text);
	}
	
	sub __addTextAsFile{
		my $tar = shift || confess "need tar filehandle";
		my $logicalFileName = shift || confess "need logical filename to add to tar";
		my $text = shift || confess "need text ref";
		
		confess "text is not defined" unless (defined($$text));
		
		debug "  adding some text to $logicalFileName";
		debug "   length ".length($$text);
		debug "   text:$$text";
		
		my $fh = new IO::Scalar $text || confess "could not open $$text";
		$$tar->AddFile($logicalFileName,length($$text),$fh);
	}
	
	sub addFilesInNoPackage{
		my $tar = shift || confess "need tar filehandle";
		my $filesInNoPackageList = shift || confess "need hash ref for file list";
		
		verbose "adding no-package files to archive";
		
		my $dirForFilesFromNoPackage = 'no_package';
		$$tar->AddLink($dirForFilesFromNoPackage,$dirForFilesFromNoPackage,('typeflag'=>5));
		
		while (my($file, $linkDestination) = each %{$filesInNoPackageList}) {
			my $path = $dirForFilesFromNoPackage."".$file;
			
			debug "adding $file as $path";
			
			if ( length($linkDestination) == 0){
				open my $fh, "<$file" || confess "could not open $file";
				$$tar->AddFile($path,-s $fh,$fh);
				close($fh);
			}
			else{
				# symbolic link needs special flag
				$$tar->AddLink($path,$linkDestination,('typeflag'=>2));
			}
			
		}
	}
	
	
	sub getOutFileHandle{
		my $file = '> '.$params->{'outputfile'};
					
		if ( defined($params->{'compressionCommand'}) ){
			$file = "| ".$params->{'compressionCommand'}." -".$params->{'compressionLevel'}." $file";
		}			
		
		debug "using file: $file";
		
		return IO::File->new("$file") || confess "could not open $file for writing";
	}
}

sub createDiffOfFiles{
	my $changed_files =shift;
	my $file_to_package_map =shift;
	
	verbose "create diff for changed files";
	
	my $packages = &findPackagesFromChangedFiles($changed_files,$file_to_package_map);
	
	my @diffs;
	
	while (my ($package, $files) = each %{$packages}) {
		my $tempDir = &downloadPackageAndExtract($package);
		my $diff = &makediff($tempDir,$files);
		push @diffs, $diff;
	};
	
	return \@diffs;
	
	sub makediff{
		confess "need 2 params " if (scalar(@_) != 2);		
		
		my $tempdir = shift;	# in case package could not be downloaded
					# tempdir is undefined
		my $files = shift || confess "need list of files";
		
		my %diff = ();
		
		if (defined($tempdir)){
			my $currentWD = cwd;
			chdir $tempdir;
			
			grep{ 
				debug "diffing $_\n";
				
				my $changed = $_;
				(my $original = $_) =~s/^\///o;
					
				if (-T ){ # if text-file
					debug " in $tempdir";
					
					my $return = &execute("diff -u $original $changed");
					my $diff = $return->{'output'};
					
					if ( defined($diff) ){
						$diff{$changed} = {'type' => 'text', 'data' => $diff, 'comment' => 'unified diff'};
					}
				}else{
					my ($fh,$tempfile) = tempfile( CLEANUP => 1, UNLINK => 1 );
					
					&execute("bsdiff $original $changed $tempfile");
					
					my $binaryDiff = read_file( $tempfile, { binmode => ':raw' } ) ;
					
					my $encoded = MIME::Base64::encode($binaryDiff);
					$diff{$changed} = {'type' => 'binary', 'data' => $encoded, 'comment' => 'base64 encoded bsdiff' };
				}
			}@{$files};
			
			chdir $currentWD;
		}
		
		return \%diff;
	}
		
	sub downloadPackageAndExtract{
		my $package = shift || confess "need package";
		my $tempdir = tempdir( CLEANUP => 1, UNLINK => 1 );
		
		verbose "downloading & extracting '$package'";
		
		my $file = &checkIfPackageAlreadyDownloaded(\$package,\$tempdir);
				
		if ( defined $file ){
			my $currentWD = cwd;
			chdir $tempdir;
		
			mkdir("extracted");
			debug "extracting $file";
			&execute("dpkg-deb -x $file extracted");
			
			chdir $currentWD;
			
			return $tempdir . "/extracted";
		}
		
		return undef;
		
		sub checkIfPackageAlreadyDownloaded{
			my $package = shift || confess "need package";	
			my $tempdir = shift || confess "need tempdir";
			
			
			my $return = &execute("apt-get download --print-uris $$package");
			if ($return->{'output'} =~ m/^'([^']+)' ([^\ ]+) (\d+) ((.+):([a-f0-9]+))$/o ){
				my ($url,$file,$size,$hashType,$hashsum) = ($1,$2,$3,$5,$6);
				
				my $cacheDir = "/var/cache/apt/archives/";
				my $currentWD = cwd;
				chdir $cacheDir;
				
				if (-f $file){
					my $return = &execute($hashType."sum $file");
					my $output = $return->{'output'};
					$output =~ m/^([a-f0-9]+)/o;
					
					if ( $1 eq $hashsum){
						debug "checksum matched";
					}else{
						debug "redownloading $$package (checksum failed)";
						&execute("apt-get download $$package")
					}
				}else{
					debug "downloading $$package (missed file)";
					&execute("apt-get download $$package")
				}
				
				debug "copy file to tempdir ($$tempdir)";
				copy($file,$$tempdir);
				
				chdir $currentWD;
			
				return $file;
			}
						
			my $message = "could not find any sources for package $$package";
			die "ERROR $message" 	if ( $params->{'fail-on-missing-package-source'});
			
			return undef;			
		}
	}

	sub findPackagesFromChangedFiles{
		my @changedFiles = @{$_[0]};
		my $file_to_package_map = $_[1];
		
		my %packages;
		
		grep{
			my $file = $_;
			my $package = ${$file_to_package_map->{$file}};
			debug "found change in $package";
			
			if ( !exists($packages{$package})){
				$packages{$package} = [];
			}
			
			push @{$packages{$package}}, $file;
		}@changedFiles;
		
		return \%packages;
	}
}

sub findChangedFiles{
	my $listOfDirs 		= shift || confess "need list of dirs";
	my $excludes 		= shift || confess "need list of excludes";
	my $file_to_package_map = shift || confess "need file to package map";
	
	verbose "find changed files";
	
	my %packages = map{ $$_ => 1} (values %{$file_to_package_map});
	
	my @packages = @{&filterOutNotInstalledPackages(\%packages)};
	
	my $changedFiles = {
		'changed' => [],
		'missing' => []
	};
	
	my $max = scalar(@packages);
	#~ verbose "$max";
	my $step = 50;
	while($max > 0){
		$step = $max if ($max < $step);
		my @temporaryList = splice @packages, 0, $step;
		$changedFiles = &checkHashSums($listOfDirs,$excludes,$changedFiles,join(' ',@temporaryList));
		
		$max -= $step ;
	}
	
	return $changedFiles;
	
	sub filterOutNotInstalledPackages{
		my $packages = shift || confess "need hash ref";
		
		my $command = 'dpkg-query -l | grep ^ii | awk {\'print $2\'} | xargs';
		my $return = &execute($command);
		my @installedPackages = split(/\ +/,$return->{'output'});
		my %installedPackages = map { $_ => 1 } @installedPackages;
				
		my @verifiedInstalledPackages =();
		grep{
			push @verifiedInstalledPackages, $_ if ( exists $installedPackages{$_});
		}(keys %{$packages});
		
		return \@verifiedInstalledPackages;
	}
	
	sub checkHashSums{	
		my $listOfDirs 		= shift || confess "need list of dirs";
		my $excludes 		= shift || confess "need list of excludes";
		my $changedFiles 	= shift || confess "need changed files";
		my $packages 		= shift || confess "need package string";
		
		my $command = "debsums -ec ".$packages;
		my $config = {
			'outSub' 	=> \&handleOutput,
			'outArgs'	=> [$listOfDirs,$excludes,$changedFiles]
		};
		&execute($command,$config);
		
		sub handleOutput{
			my $file 		= shift || confess "missing \$file";
			my $listOfDirs 		= shift || confess "need list of dirs";
			my $excludes 		= shift || confess "need list of excludes";
			my $changedFiles 	= shift || confess "need changed files";
		
			if ( $file =~ /^debsums: missing file (\/[^ ]+)/){
				my $match = $1;
				if (&shouldBeInSourceAndNotExcluded($listOfDirs,$excludes,$match)){
					push @{$changedFiles->{'missing'}}, $match;
				}			
			}else{
				chomp($file);
				
				if (&shouldBeInSourceAndNotExcluded($listOfDirs,$excludes,$file)){
					push @{$changedFiles->{'changed'}}, $file;
				}
			}
		}
		
		return $changedFiles;
	}
	sub shouldBeInSourceAndNotExcluded{
		my $listOfDirs 	= shift || confess "need list of dirs";
		my $excludes 	= shift || confess "need list of excludes";
		my $item	= shift || confess "need item to check against";
		
		my $isOk = 0;
		
		grep{
			if ( !$isOk && $item =~ m{^$_} ){
				$isOk = 1;
			}
		}@{$listOfDirs};
		
		grep{	
			# because of '/' in excludes we need another expression for m//
			return 0 if ($item =~ m{^$_} );	
		}@{$excludes};
		
		return $isOk;
	}
}

sub findFilesToBeBackedUpBecauseInNoPackage{
	my $listOfDirs 	= shift || confess "need list of dirs";
	my $excludes 	= shift || confess "need list of excludes";
	
	my $files_in_no_package = {};
		
	# could not make the wanted sub an inner _named_ sub
	# because the variable '$files_in_no_package' will not stay shared
	# see  http://perldoc.perl.org/perldiag.html => Variable "%s" will not stay shared
	
	find({ wanted => sub {
		my $item = $_;

		# because of '/' in excludes we need another expression for m//
		grep{	return if ($item =~ m{^$_} );	}@{$excludes};
		
		my $package = $file_to_package_map->{$item};
		if ( !defined($package) ){
			if (-d $item){
				# do nothing
			}
			elsif(-l $item){
				debug "link ".readlink($item);
				$files_in_no_package->{$item} = readlink $item;
			}
			elsif (-f $item){
				debug "file $item";
				$files_in_no_package->{$item} = '';
			}
		}
	}
	, follow => 0, no_chdir=>1 }, @{$listOfDirs});

	return $files_in_no_package;
}

sub populateFileToPackageMap{
	my $listOfDirs 	= shift || confess "need list of dirs";
	my $excludes 	= shift || confess "need list of excludes";
	
	verbose "reading index of files/packages";
	
	my $package_to_file_map = &populatePackageToFileMap($listOfDirs,$excludes);
	
	my $file_to_package_map = {};
	
	while (my ($package, $filesArray) = each %{$package_to_file_map}) {
		grep{
			$file_to_package_map->{$_} = \$package;
		}@{$filesArray};
	}
	
	return $file_to_package_map;
	
	sub populatePackageToFileMap{
		my $listOfDirs 	= shift || confess "need list of dirs";
		my $excludes 	= shift || confess "need list of excludes";
		
		my %package_to_file_map = ();
		
		open(DLOCATEDB,"</var/lib/dlocate/dlocatedb") || confess "$^E";
		while(<DLOCATEDB>){
			my ($package,$file) = $_ =~ /([^:]+): (.+)/;
			
			grep{
				if ($file =~ m{^$_}){
					# because of '/' in excludes we need another expression for m//
					grep{	next if ($file =~ m{^$_} );	}@{$excludes};
					
					if (!exists($package_to_file_map{$package})){
						$package_to_file_map{$package} = [];
					}
					
					push @{$package_to_file_map{$package}}, $file;
				}
			}@{$listOfDirs}
		}
		close(DLOCATEDB);
		
		return \%package_to_file_map;
	}
}

sub parseOptionsAndGiveHelp{
	
	my $help = <<EOT;	
	-h, --help		show this help 
	
	-f, --file		file to be written to, if file is - then STDOUT will be used
	    --fail-on-missing-package-source	
				sometimes packages were installed manually and changed files could
				not be effectivily diffed (in case diff is complete file)
	--no-apt-clone		skipping apt-clone, no information about installed packages will be saved
	-s, --source		use these as source directories (for multiple sources use multiple times )
				e.g. -s a -s b -s c
	-x, --exclude		exclude sources to backed up (same notation as --source)
	
debugging
	-c, --print-o-a-e	prints options and exits
	-d, --debug		to be verbose and print some debug infos
	-n, --dryrun		just make a dryrun, write nothing
	-p, --print-options	prints configuration (helps to see defaults)
	-q, --quiet		supress all output
	-v, --verbose		be verbose

compression
	-b, --bzip2		use bzip2 for compression (output will be .tar.bz2)
	-g, --gzip		use gzip for compression (output will be .tar.gz)
	-l, --lzo		use lzop for compression (output will be .tar.lzo)
	--level=#		compression level to use (0..9)
	-z, --xz		use xz for compression (output will be .tar.xz)
EOT

	sub bye{
		print STDERR 'ERROR '.join(' ',@_),"\n";
		exit 1;
	}

	my @sourceDirectories = ();
	my @excludes = ();
	my $exitAfterOptions = 0;
	
	GetOptions (
	    'h|help'				=> sub { print $help; exit },
	    
	    'f|file=s'				=> \$params->{'outputfile'},
	    'fail-on-missing-package-source=s'	=> \$params->{'fail-on-missing-package-source'},
	    'no-apt-clone'			=> \$params->{'no-apt-clone'},
	    's|source=s'			=> \@sourceDirectories,
	    'x|exclude=s'			=> \@excludes,
	    
	    'c|print-o-a-e'			=> sub { $params->{'print-options'} = 1; $exitAfterOptions = 1;},
	    'd|debug'				=> \$params->{'debug'},
	    'n|dryrun'				=> \$params->{'dryrun'},
	    'p|print-options'			=> \$params->{'print-options'},
	    'q|quiet'				=> \$params->{'quiet'},
	    'v|verbose'				=> \$params->{'verbose'},
	    
	    'b|bzip2'				=> sub { $params->{'compression'} = 'bzip2'; },
	    'g|gzip'				=> sub { $params->{'compression'} = 'gzip'; },
	    'l|lzo'				=> sub { $params->{'compression'} = 'lzo'; },
	    'level=i'				=> \$params->{'compressionLevel'},
	    'z|xz'				=> sub { $params->{'compression'} = 'xz'; },
	) or bye "Try '$0 --help' for more information.\n";
	
	bye "valid compression levels only 0-9 not ".$params->{'compressionLevel'}."\n\n$help" if ( $params->{'compressionLevel'} !~ /^[0-9]$/);
	
	$params->{'sourceDirectories'} = \@sourceDirectories 	if (scalar(@sourceDirectories)>0);
	$params->{'excludes'} = \@excludes 			if (scalar(@excludes)>0);
	
	grep{
		bye "missing source $_\n\n$help" unless (-e)
	}@{$params->{'sourceDirectories'}};
	
	bye "quiet and verbose/debug are mutually exclusive \n\n$help" if ($params->{'quiet'} && ($params->{'debug'} || $params->{'verbose'}));
	
	$params->{'verbose'}=1 		if ($params->{'debug'});
	$params->{'print-options'}=1 	if ($params->{'debug'});

	$params->{'debug'}=0 		if ($params->{'quiet'});
	$params->{'print-options'}=0 	if ($params->{'quiet'});
	$params->{'verbose'}=0 		if ($params->{'quiet'});
	
	if ($params->{'dryrun'}){
		$params->{'outputfile'} ="/dev/null";
	}else{
		if ($params->{'outputfile'} eq ''){
			$params->{'outputfile'} = 'backup.tar';
			
			my %extensions = (
				'bzip2'	=> '.bz2',
				'gzip'	=> '.gz',
				'lzo'	=> '.lzo',
				'xz'	=> '.xz',
				
				'none'	=> ''
			);
			
			$params->{'outputfile'} .= $extensions{ $params->{'compression'}};
			
			verbose "default output goes to ".$params->{'outputfile'};
			
		}
		elsif ($params->{'outputfile'} eq '-'){
			$params->{'outputfile'} = '/dev/stdout';
		}
	}
	
	$params->{'compressionCommand'} = &findAppropriateCompressionCommand($params->{'compression'}) if ( $params->{'compression'} ne 'none');
	
	if ($params->{'print-options'}){
		local $Data::Dumper::Sortkeys=1;
		print STDERR Dumper($params);
		exit if $exitAfterOptions;
	}
	
	
	# maybe we can use parallel compression
	sub findAppropriateCompressionCommand{
			
		my %method2commandMap =(
			'bzip2' => ['pbzip2','bzip2'],
			'gzip'	=> ['pigz', 'gzip'],
			'lzo'	=> ['lzop'],
			'xz'	=> ['xzz']
		);
		my $method = shift || confess "need a compression command";
		confess "unknown command $method " if ( !exists($method2commandMap{$method}));
		
		debug "trying to find command for $method";
		
		grep{
			my $cmd = $_;
			my $return = &execute('which '.$cmd,{'quiet' => 1});
			debug " checked and found $cmd as compression command";
			return $cmd if ($return->{'exit-code'} == 0);
		} @{$method2commandMap{ $method }};
		
		confess "could not find any compression commands for '".$method."'";
	}
}


sub debug{
	my $line = shift || confess "could not show undefined text";
	
	if ($params->{'debug'} eq 1 ){
		chomp($line);
		print STDERR "DEBUG $line\n";
	}
}

sub verbose{
	my $line = shift || confess "could not show undefined text";
	
	if ($params->{'verbose'} eq 1 ){
		chomp($line);
		print STDERR "$line\n";
	}
}

sub execute{
	my $command 	= shift || confess 'need command to be executed';
	my $config 	= shift || {};
		
	my $output = "";
	my $_config = { 
		'quiet' => $params->{'quiet'},
		'_sub'	=> sub{
			my $handle 		= shift || confess "missing handle";
			my $innerSub 		= shift || confess "missing inner sub";
			my $innerSubArguments	= shift || [];
			
			while(<$handle>){
				$innerSub->( \$_,@{$innerSubArguments});
			}
			close($handle);
		},
		'errSub' => sub{
			my $line = shift || confess "missing \$line";
			my $config = shift || confess "missing config";
			
			warn "WARN ".$$line if (!$config->{'quiet'});
		},
		'errArgs' => [],
		'outSub' => sub{
			my $line = shift || confess "missing \$line";
			my $output = shift || confess "missing output";

			debug $_;
			$$output .= $$line;
		},
		'outArgs' => [\$output],
	};
	
	$_config->{'errArgs'} = [$_config];
	
	grep{	
		my $key = $_;
		# merge missing configs into passed one
		if (!exists($config->{$key})){
			$config->{$key} = $_config->{$key};
		}
	}(keys %{$_config});
	
	debug 'executing '.$command;
	
	my $pid = open3(*IN,*OUT,*ERR,$command) || confess $^E;
	close(IN);
	
	my $childPid = fork();
	
	if ($childPid==0){
		$config->{'_sub'}->(\*ERR,$config->{'errSub'},$config->{'errArgs'});
		exit;
	}
	
	$config->{'_sub'}->(\*OUT,$config->{'outSub'},$config->{'outArgs'});
	
	#~ waitpid($pid,WNOHANG);
	
	debug "exit code $?";
	debug "output:$output";
	
	return {'output' => $output, 'exit-code' => $?};
}