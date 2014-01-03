#!perl

package Main;

$|=1;
use strict;
use warnings;

use Archive::Tar::Stream;
use Carp qw/longmess cluck/;
use Carp::Source;
use Cwd;
use Data::Dumper;
use File::Basename;
use File::Copy;
use File::Find;
use File::Slurp;
use File::Temp qw/tempfile/;
use Getopt::Long qw/:config bundling/;
use IO::Scalar;
use MIME::Base64 ();
use Time::HiRes qw/time/;

my $original = cwd;
sub confess{ 
	chdir $original; 
	Carp::confess @_; 
};

my $start = time;
my $params = { 
	'sourceDirectories' 	=> [
		'/etc',
		'/usr',
		'/var/log',
		'/var/spool',
		],
	'excludes'		=> [
		'/var/cache',
		#~ '/usr/lib','/usr/share','/usr/local',
		#~ '/var/lib/dpkg',
		#~ '/var/lib/dkms',
		#~ '/var/lib/dlocate',
		#~ #'/var/lib/gems',
		#~ '/var/lib/mlocate',
	],
	'fail-on-missing-package-source' => 0,
	'no-pkg-clone'		=> 0,
	'outputfile'		=> '',
	
	'compression'		=> 'gzip',
	'compressionCommand'	=> undef,
	'compressionLevel'	=> 9,
	
	'debug' 		=> 0, 
	'dryrun' 		=> 0,
	'print-options'		=> 0,
	'quiet'			=> 0,
	'verbose'		=> 1,
};

&parseOptionsAndGiveHelp($params);

my $packageSystem = Debian->new($params);

my $file_to_package_map = &populateFileToPackageMap($params->{'sourceDirectories'},$params->{'excludes'},$packageSystem);
my $filesInNoPackageList = &findFilesToBeBackedUpBecauseInNoPackage($params->{'sourceDirectories'},$params->{'excludes'},$file_to_package_map);
my $changed_files_map = &findChangedFiles($params->{'sourceDirectories'},$params->{'excludes'}, $file_to_package_map,$packageSystem);
my $diffs = &createDiffOfFiles($changed_files_map->{'changed'},$file_to_package_map,$packageSystem);

&createBackupFile($filesInNoPackageList,$diffs,$changed_files_map->{'missing'}, $packageSystem);

&verbose('duration '. ( time - $start ) . "ms\n");
#~ <STDIN>;

# ---- subs -----

sub debug	{ Util::debug(@_); }
sub verbose	{ Util::verbose(@_); }
sub execute	{ Util::execute(@_); }

sub createBackupFile{
	confess "need 4 params " if (scalar(@_) != 4);
	
	my $filesInNoPackageList 	= shift || confess "need files in no package";
	my $diffs 			= shift || confess "need diffs";
	my $missingFiles 		= shift || confess "need missing files";
	my $packageSystem 		= shift || confess "need missing packageSystem";
	
	&verbose("creating backup file");
	
	my $tar = Archive::Tar::Stream->new(outfh => &getOutFileHandle());
	
	&addReadme(\$tar);
	&addChangedFiles(\$tar,$diffs);
	&addMissingFiles(\$tar,$missingFiles);
	&addFilesInNoPackage(\$tar,$filesInNoPackageList);
	
	&verbose("skipping package clone") 	if ( $params->{'no-pkg-clone'});
	$packageSystem->savePackages(\$tar)	if (!$params->{'no-pkg-clone'});
	
	$tar->FinishTar();
	
	sub addChangedFiles{
		my $tar = shift || confess "need tar filehandle";
		my $diffs = shift || confess "need diffs";
		
		&verbose("adding diffs to archive");
		
		my $dirForChangedFiles = 'changed';
		$$tar->AddLink($dirForChangedFiles,$dirForChangedFiles,('typeflag'=>5));
		
		grep{
			while (my ($file, $metadata) = each %{$_}) {
				my $path = $dirForChangedFiles."".$file;
								
				&debug("adding $file as $path");
				
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
		
		&verbose("adding missing files to archive");
		
		
		my $dirForMissingFiles = 'missing';
		$$tar->AddLink($dirForMissingFiles,$dirForMissingFiles,('typeflag'=>5));
		
		grep{
			my $path = $dirForMissingFiles."".$_;
			&debug("adding $_ as $path");
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
		
		&debug("  adding some text to $logicalFileName");
		&debug("   length ".length($$text));
		&debug("   text:$$text");
		
		my $fh = new IO::Scalar $text || confess "could not open $$text";
		$$tar->AddFile($logicalFileName,length($$text),$fh);
	}
	
	sub addFilesInNoPackage{
		my $tar = shift || confess "need tar filehandle";
		my $filesInNoPackageList = shift || confess "need hash ref for file list";
		
		&verbose("adding no-package files to archive");
		
		my $dirForFilesFromNoPackage = 'no_package';
		$$tar->AddLink($dirForFilesFromNoPackage,$dirForFilesFromNoPackage,('typeflag'=>5));
		
		my $counter = 0;
		my %directoryEntries = ();
		while (my($file, $linkDestination) = each %{$filesInNoPackageList}) {
			my $path = $dirForFilesFromNoPackage."".$file;
			
			debug("adding $file ($linkDestination) as $path");
			
			# create directory entries for entries
			# else the first entry in a directory makes the parent directory
			# entries looking like links too
			my $dir = dirname($path);
			if (!exists $directoryEntries{$dir}){
				$$tar->AddLink($dir,$dir,('typeflag'=>5));
				$directoryEntries{$dir} = \1;
			}
			
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
		
		&debug("using file: $file");
		
		return IO::File->new("$file") || confess "could not open $file for writing";
	}
}

sub createDiffOfFiles{
	confess "need 3 params " if (scalar(@_) != 3);
	
	my $changed_files 	= shift || confess "need changed files";
	my $file_to_package_map = shift || confess "need file to package map";
	my $packageSystem 	= shift || confess "need missing packageSystem";
	
	&verbose("create diff for changed files");
	
	my $packages = &findPackagesFromChangedFiles($changed_files,$file_to_package_map);
	
	my @diffs;
	
	while (my ($package, $files) = each %{$packages}) {
		my $tempDir = $packageSystem->downloadPackageAndExtract($package);
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
				&debug("diffing $_\n");
				
				my $changed = $_;
				(my $original = $_) =~s/^\///o;
					
				if (-T ){ # if text-file
					&debug(" in $tempdir");
					
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

	sub findPackagesFromChangedFiles{
		my $changedFiles 	= shift || confess "missing list of changed files";
		my $file_to_package_map = shift || confess "missing file to package map";
		
		my %packages;
		
		grep{
			my $file = $_;
			my $package = ${$file_to_package_map->{$file}};
			&debug("found change in $package");
			
			if ( !exists($packages{$package})){
				$packages{$package} = [];
			}
			
			push @{$packages{$package}}, $file;
		}@{$changedFiles};
		
		return \%packages;
	}
}

sub findChangedFiles{
	my $listOfDirs 		= shift || confess "need list of dirs";
	my $excludes 		= shift || confess "need list of excludes";
	my $file_to_package_map = shift || confess "need file to package map";
	my $packageSystem 	= shift || confess "need missing packageSystem";
	
	confess "file to package map is empty" if ( scalar(keys %{$file_to_package_map}) == 0);
	
	&verbose("find changed files");
	
	my %packages = map{ $$_ => 1} (values %{$file_to_package_map});
	
	my @packages = @{$packageSystem->filterOutNotInstalledPackages(\%packages)};
	
	my $changedFiles = {
		'changed' => [],
		'missing' => []
	};
	
	my $max = scalar(@packages);
	#~ &verbose("$max";
	my $step = 40;
	while($max > 0){
		$step = $max if ($max < $step);
		my @temporaryList = splice @packages, 0, $step;
		$changedFiles = $packageSystem->checkPackageHashSums($listOfDirs,$excludes,$changedFiles,join(' ',@temporaryList));
		
		$max -= $step ;
	}
	
	return $changedFiles;
}

sub findFilesToBeBackedUpBecauseInNoPackage{
	my $listOfDirs 		= shift || confess "need list of dirs";
	my $excludes 		= shift || confess "need list of excludes";
	my $file_to_package_map = shift || confess "need file to package map";
	
	my $files_in_no_package = {};
		
	# could not make the wanted sub an inner _named_ sub
	# because the variable '$files_in_no_package' will not stay shared
	# see  http://perldoc.perl.org/perldiag.html => Variable "%s" will not stay shared
	
	find({ wanted => sub {
		my $item = $_;

		return if (&isExcludedPath($excludes,\$item));
		
		my $package = $file_to_package_map->{$item};
		if ( !defined($package) ){
			if(-l $item){
				$files_in_no_package->{$item} = readlink $item;
			}
			elsif (-f $item){
				&debug("file $item");
				$files_in_no_package->{$item} = '';
			}
		}
	}
	, follow => 0, no_chdir=>1 }, @{$listOfDirs});

	return $files_in_no_package;
}

sub populateFileToPackageMap{
	my $listOfDirs 		= shift || confess "need list of dirs";
	my $excludes 		= shift || confess "need list of excludes";
	my $packageSystem 	= shift || confess "need missing packageSystem";
	
	&verbose("reading index of files/packages");
	
	my $package_to_file_map = $packageSystem->populatePackageToFileMap($listOfDirs,$excludes);
		
	my $file_to_package_map = {};
	
	while (my ($package, $filesArray) = each %{$package_to_file_map}) {
		grep{
			$file_to_package_map->{$_} = \$package;
		}@{$filesArray};
	}
	
	return $file_to_package_map;
}

sub parseOptionsAndGiveHelp{
	
	my $help = <<EOT;	
	-h, --help		show this help 
	
	-f, --file		file to be written to, if file is - then STDOUT will be used
	    --fail-on-missing-package-source	
				sometimes packages were installed manually and changed files could
				not be effectivily diffed (in case diff is complete file)
	--no-pkg-clone		skipping package cloning, no information about installed packages will be saved
	-s, --source		use these as source directories (for multiple sources use multiple times )
				e.g. -s a -s b -s c
	-x, --exclude		exclude sources to backed up (same notation as --source)
	
debugging
	-c, --print-o-a-e	prints options and exits
	-d, --debug		to be verbose and print some &debug(infos
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
	    'no-pkg-clone'			=> \$params->{'no-pkg-clone'},
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
	
	bye "valid compression levels only 0-9 not ".$params->{'compressionLevel'}."\n\n$help" if ( $params->{'compressionLevel'} !~ /^[0-9]$/o);
	
	$params->{'sourceDirectories'} = \@sourceDirectories 	if (scalar(@sourceDirectories)>0);
	$params->{'excludes'} = \@excludes 			if (scalar(@excludes)>0);
	
	grep{
		bye "missing source $_\n\n$help" unless (-e)
	}@{$params->{'sourceDirectories'}};
	
	bye "quiet and verbose/debug(are mutually exclusive \n\n$help" if ($params->{'quiet'} && ($params->{'debug'} || $params->{'verbose'}));
	
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
			
			&verbose("default output goes to ".$params->{'outputfile'});
			
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
		
		&debug("trying to find command for $method");
		
		grep{
			my $cmd = $_;
			my $return = &execute('which '.$cmd,{'quiet' => 1});
			&debug(" checked and found $cmd as compression command");
			return $cmd if ($return->{'exit-code'} == 0);
		} @{$method2commandMap{ $method }};
		
		confess "could not find any compression commands for '".$method."'";
	}
}

sub isAcceptedPath{
	my $listOfDirs 		= shift || confess "need list of dirs";
	my $excludes 		= shift || confess "need list of excludes";
	my $file		= shift || confess "need file";
	
	grep{
		if ($$file =~ m{^$_}){
			
			return 0 if (&isExcludedPath($excludes,$file));
			
			# not accept directories
			return 0 if (-d $$file);
			
			# accepted
			return 1;
		}
	}@{$listOfDirs};
	
	return 0; # no match
}

sub isExcludedPath{
	my $excludes 		= shift || confess "need list of excludes";
	my $file		= shift || confess "need file";
	
	# because of '/' in excludes we need another expression for m//
	grep{	return 1 if ($$file =~ m{^$_} )	}@{$excludes};
	
	return 0;
}

# ----------------------------------------------------------------------------------
#
#  Util
#
# ----------------------------------------------------------------------------------

package Util;

use strict;
use warnings;

use Carp qw/longmess cluck confess/;
use Carp::Source;
use IPC::Open3;

sub debug{
	confess "could not show undefined text" if (scalar(@_) == 0);
	
	if ($params->{'debug'} eq 1 ){
		my $line = join('',@_);
		chomp($line);
		print STDERR "DEBUG $line\n";
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
			
			print STDERR "WARN ".$$line if (!$config->{'quiet'});
		},
		'errArgs' => [],
		'outSub' => sub{
			my $line = shift || confess "missing \$line";
			my $output = shift || confess "missing output";

			&debug($_);
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
	
	&debug('executing '.$command);
	
	my $pid = open3(*IN,*OUT,*ERR,$command) || confess $^E;
	close(IN);
	
	my $childPid = fork();
	
	if ($childPid==0){
		$config->{'_sub'}->(\*ERR,$config->{'errSub'},$config->{'errArgs'});
		exit;
	}
	
	$config->{'_sub'}->(\*OUT,$config->{'outSub'},$config->{'outArgs'});
	
	&debug("exit code for \"$command\" code $?");
	&debug("output:$output");
	
	return {'output' => $output, 'exit-code' => $?};
}

sub verbose{
	confess "could not show undefined text" if (scalar(@_) == 0);
	
	if ($params->{'verbose'} eq 1 ){
		my $line = join('',@_);
		chomp($line);
		print STDERR "$line\n";
	}
}

# ----------------------------------------------------------------------------------
#
#  Debian
#
# ----------------------------------------------------------------------------------

package Debian;

use strict;
use warnings;

use Carp qw/longmess cluck confess/;
use Carp::Source::Always;
use Cwd;
use Data::Dumper;
use File::Basename;
use File::Copy;
use File::Spec::Functions qw/catfile/;
use File::Temp qw/tempdir/;

sub debug	{ Util::debug(@_); }
sub verbose	{ Util::verbose(@_); }
sub execute	{ Util::execute(@_); }

sub new{
	my $class = shift;
	my $params = shift  || confess "need to now params";
	
	my $self = {};
	bless $self, $class;
	
	$self->{'params'} = $params;
	$self->{'addFileAptClone'} = sub {
		my $tar = shift || confess "need tar filehandle";
		
		my $basename = "clone";
		my $name = $basename.".apt-clone.tar.gz";
		my $tempdir = tempdir(CLEANUP=>0,UNLINK=>0);
		my $fullname = catfile($tempdir,$name);

		&verbose("doing apt-clone");
		
		&verbose("executing apt-clone");
		my $currentWD = cwd;
		chdir $tempdir;
			
		&debug("changed into $tempdir");
		execute("apt-clone clone --with-dpkg-status --with-dpkg-repack ".$basename);
		&debug("finished apt-clone");
		
		chdir $currentWD;
		
		open my $fh,"<$fullname" || confess "could not read $fullname: $^E";
		$$tar->AddFile($name,-s $fh, $fh);
		close($fh);
		&debug("Done");
	};
	
	return $self;
}

sub checkPackageHashSums{	
	confess "need 5 params " if (scalar(@_) != 5);
	
	my $self     		= shift || confess "need myself";
	my $listOfDirs 		= shift || confess "need list of dirs";
	my $excludes 		= shift || confess "need list of excludes";
	my $changedFiles 	= shift || confess "need changed files";
	my $packages 		= shift || confess "need package string";
	
	my $command = "debsums -ac ".$packages;
	my $config = {
		'outSub' 	=> \&handleOutput,
		'outArgs'	=> [$listOfDirs,$excludes,$changedFiles]
	};
	execute($command,$config);

	sub handleOutput{
		my $file 		= shift || confess "missing \$file";
		my $listOfDirs 		= shift || confess "need list of dirs";
		my $excludes 		= shift || confess "need list of excludes";
		my $changedFiles 	= shift || confess "need changed files";
	
		if ($$file =~ /^\// ){
			chomp($$file);
			
			if (Main::isAcceptedPath($listOfDirs,$excludes,$file)){
				push @{$changedFiles->{'changed'}}, $$file;
			}
		}
		elsif ( $$file =~ /^debsums: missing file (\/[^ ]+)/o){
			my $match = $1;
			if (Main::isAcceptedPath($listOfDirs,$excludes,\$match)){
				push @{$changedFiles->{'missing'}}, $match;
			}			
		}
		
		return $changedFiles;
	}
	
	return $changedFiles;
}

sub filterOutNotInstalledPackages{
	confess "need 2 params " if (scalar(@_) != 2);
	my $self     = shift || confess "need myself";
	my $packages = shift || confess "need hash ref";
	
	my $command = 'dpkg-query -l | grep ^ii | awk {\'print $2\'} | xargs';
	my $return = execute($command);
	my @installedPackages = split(/\ +/,$return->{'output'});
	my %installedPackages = map { $_ => 1 } @installedPackages;
			
	my @verifiedInstalledPackages =();
	grep{
		push @verifiedInstalledPackages, $_ if ( exists $installedPackages{$_});
	}(keys %{$packages});
	
	return \@verifiedInstalledPackages;
}

sub savePackages{
	confess "need 2 params " if (scalar(@_) != 2);
	my ( $self, $tarStreamRef ) = @_;
	
	$self->{'addFileAptClone'}->($tarStreamRef);
}

sub downloadPackageAndExtract{
	my $self    = shift || confess "need myself";
	my $package = shift || confess "need package";
	my $tempdir = tempdir( CLEANUP => 1, UNLINK => 1 );
	
	&verbose("downloading & extracting '$package'");
	
	my $file = &checkIfPackageAlreadyDownloaded(\$package,\$tempdir);
			
	if ( defined $file ){
		my $currentWD = cwd;
		chdir $tempdir;
	
		mkdir("extracted");
		&debug("extracting $file");
		execute("dpkg-deb -x $file extracted");
		
		chdir $currentWD;
		
		return $tempdir . "/extracted";
	}
	
	return undef;
	
	sub checkIfPackageAlreadyDownloaded{
		my $package = shift || confess "need package";	
		my $tempdir = shift || confess "need tempdir";
		
		
		my $return = execute("apt-get download --print-uris $$package");
		if ($return->{'output'} =~ m/^'([^']+)' ([^\ ]+) (\d+) ((.+):([a-f0-9]+))$/o ){
			my ($url,$file,$size,$hashType,$hashsum) = ($1,$2,$3,$5,$6);
			
			my $cacheDir = "/var/cache/apt/archives/";
			my $currentWD = cwd;
			chdir $cacheDir;
			
			if (-f $file){
				my $return = execute($hashType."sum $file");
				my $output = $return->{'output'};
				$output =~ m/^([a-f0-9]+)/o;
				
				if ( $1 eq $hashsum){
					&debug("checksum matched");
				}else{
					&debug("redownloading $$package (checksum failed)");
					execute("apt-get download $$package")
				}
			}else{
				&debug("downloading $$package (missed file)");
				execute("apt-get download $$package")
			}
			
			&debug("copy file to tempdir ($$tempdir)");
			copy($file,$$tempdir);
			
			chdir $currentWD;
		
			return $file;
		}
					
		my $message = "could not find any sources for package $$package";
		die "ERROR $message" 	if ( $params->{'fail-on-missing-package-source'});
		
		return undef;			
	}
}

sub populatePackageToFileMap{
	my $self    	= shift || confess "need myself";
	my $listOfDirs 	= shift || confess "need list of dirs";
	my $excludes 	= shift || confess "need list of excludes";
	
	my $package_to_file_map = &retrieveFromDlocateDB($listOfDirs,$excludes);
	
	confess "need no empty package map" if ( scalar(keys %{$package_to_file_map}) == 0 );
	
	#~ print Dumper($package_to_file_map);exit;
	
	return $package_to_file_map;
	
	sub retrieveFromDlocateDB{
		my $listOfDirs 	= shift || confess "need list of dirs";
		my $excludes 	= shift || confess "need list of excludes";
		my $package_to_file_map ={};
		
		open(DLOCATEDB,"</var/lib/dlocate/dlocatedb") || confess "$^E";
		while(<DLOCATEDB>){
			my $line = $_;
			my ($package, $file) = $line =~ m/^([^:]+).+?(\/.+)$/o;
			
			if ( Main::isAcceptedPath($listOfDirs,$excludes,\$file) ){
				if (!exists($package_to_file_map->{$package})){
					$package_to_file_map->{$package} = [];
				}
				
				push @{$package_to_file_map->{$package}}, $file;	
			}
		}
		close(DLOCATEDB);
		
		return $package_to_file_map;
	}
}