#!perl

$|=1;
use strict;
use subs qw/debug verbose/;
use warnings;

use Archive::Tar::Stream;
use Carp qw/longmess cluck confess/;
#~ use Carp::Always;
use Carp::Source::Always;
use Cwd;
use Data::Dumper;
use File::Copy;
use File::Find;
use File::Slurp;
use File::Spec::Functions qw(catfile);
use File::Temp qw/ tempdir tempfile/;
use Getopt::Long qw/:config bundling/;
use IO::Scalar;
use MIME::Base64 ();
use POSIX qw(mkfifo);
use Time::HiRes qw/time/;


my $start = time;
my $original = cwd;	# stay in original working directory
my $params = { 
	'compression'	=> 'none',
	'debug' 	=> 0, 
	'dryrun' 	=> 0, 
	'verbose'	=> 1,
};

&parseOptionsAndGiveHelp($params);

my $file_to_package_map = &populateFileToPackageMap;
my $filesInNoPackageList = &findFilesToBeBackedUpBecauseInNoPackage;
my $changed_config_files_map = &findChangedConfigFiles;
my $diffs = &createDiffOfChangedConfigFiles($changed_config_files_map);

&createBackupFile($filesInNoPackageList,$diffs);

verbose 'duration '. ( time - $start ) . "ms\n";
<STDIN>;

# ---- subs -----

sub createBackupFile{
	my ($filesInNoPackageList,$diffs) = @_;
	
	chdir $original;
	
	verbose "creating backup file";
	
	my $tar = Archive::Tar::Stream->new(outfh => &getOutFileHandle());
	
	&addReadme(\$tar);
	&addChangedFiles(\$tar,$diffs);
	&addFilesInNoPackage(\$tar,$filesInNoPackageList);
	&addAptClone(\$tar);
	
	$tar->FinishTar();
	
	sub addAptClone{
		my $tar = shift || confess "need tar filehandle";
			
		
		my $basename = "clone";
		my $name = $basename.".apt-clone.tar.gz";
		my $tempdir = tempdir(CLEANUP=>0,UNLINK=>0);
		my $fullname = catfile($tempdir,$name);

		verbose "$fullname";
		
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
	
	sub addReadme{
		my $tar = shift || confess "need tar filehandle";
		
		my $text = <<EndOfReadme;

some information on these entries:
--------------------------------------------

- no_package		files, which are not originally from any package installed on the system

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
		
		my $fh = new IO::Scalar $text || confess "could not open $_";
		$$tar->AddFile($logicalFileName,length($$text),$fh);
	}
	
	sub addFilesInNoPackage{
		my $tar = shift || confess "need tar filehandle";
		my $filesInNoPackageList = shift || confess "need array ref for file list";
		
		verbose "adding no-package files to archive";
		
		my $dirForFilesFromNoPackage = 'no_package';
		grep{
			my $path = $dirForFilesFromNoPackage."".$_;
			
			debug "adding $_ as $path";
			
			open my $fh, "<$_" || confess "could not open $_";
			$$tar->AddFile($path,-s $fh,$fh);
			close($fh);
			
		}@{$filesInNoPackageList};
	}
	
	
	sub getOutFileHandle{
		my $file;
		if ($params->{'dryrun'} eq 1){
			$file ="/dev/null";
		}
		else{
			$file = "backup.tar";
		}
		
		return IO::File->new(">$file") || confess "could not open $file for writing";
	}
}

sub createDiffOfChangedConfigFiles{
	my $changed_config_files_map =shift;
	
	verbose "create diff for changed config files";
	
	my @changedFiles = @{$changed_config_files_map->{'changed'}};	
	my $packages = &findPackagesFromChangedFiles(\@changedFiles);
	
	my @diffs;
	
	while (my ($package, $files) = each %{$packages}) {
		# TODO maybe parallel runs
		my $tempDir = &downloadPackageAndExtract($package);
		my $diff = &makediff($tempDir,$files);
		push @diffs, $diff;
	};
	
	return \@diffs;
	
	sub makediff{
		my $tempdir = shift || confess "need tempdir";
		my $files = shift || confess "need list of files";
		
		chdir $tempdir;
		
		my %diff;
		
		grep{ 
			debug "diffing $_\n";
			
			my $changed = $_;
			(my $original = $_) =~s/^\///o;
				
			if (-T ){ # if text-file
				debug " in $tempdir";
				
				my $diff = &execute("diff -u $original $changed");
				
				if ( defined($$diff) ){
					$diff{$changed} = {'type' => 'text', 'data' => $$diff, 'comment' => 'unified diff'};
				}
			}else{
				my ($fh,$tempfile) = tempfile( CLEANUP => 1, UNLINK => 1 );
				
				&execute("bsdiff $original $changed $tempfile");
				
				my $binaryDiff = read_file( $tempfile, { binmode => ':raw' } ) ;
				
				my $encoded = MIME::Base64::encode($binaryDiff);
				$diff{$changed} = {'type' => 'binary', 'data' => $encoded, 'comment' => 'base64 encoded bsdiff' };
			}
		}@{$files};
		
		return \%diff;
	}
		
	sub downloadPackageAndExtract{
		my $package = shift || confess "need package";
		my $tempdir = tempdir( CLEANUP => 1, UNLINK => 1 );
		
		verbose "downloading & extracting '$package'";
		
		my $file = &checkIfPackageAlreadyDownloaded(\$package,\$tempdir);
		
		sub checkIfPackageAlreadyDownloaded{
			my $package = shift || confess "need package";	
			my $tempdir = shift || confess "need tempdir";
			
			
			my $cacheDir = "/var/cache/apt/archives/";
			chdir $cacheDir;
			
			my $output = &execute("apt-get download --print-uris $$package");
			$$output =~ m/^'([^']+)' ([^\ ]+) (\d+) ((.+):([a-f0-9]+))$/o;
			my ($url,$file,$size,$hashType,$hashsum) = ($1,$2,$3,$5,$6);
			
			if (-f $file){
				my $output = &execute($hashType."sum $file");
				$$output =~ m/^([a-f0-9]+)/o;
				
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
			
			return $file;
		}
		
		chdir($tempdir);
		
		mkdir("extracted");
		debug "extracting $file";
		&execute("dpkg-deb -x $file extracted");
		
		return $tempdir . "/extracted";
	}

	sub findPackagesFromChangedFiles{
		my @changedFiles = @{$_[0]};
		my %packages;
		
		grep{
			my $file = $_;
			my $package = $file_to_package_map->{$file};
			debug "found change in $package";
			
			if ( !exists($packages{$package})){
				$packages{$package} = [];
			}
			
			push @{$packages{$package}}, $file;
		}@changedFiles;
		
		return \%packages;
	}
}

sub findChangedConfigFiles{
	verbose "find changed config files";
	
	my %changedFiles = (
		'changed' => [],
		'missing' => []
	);
	
	open(PROC,"debsums -ec | ") || confess $^E;
	while(<PROC>){
		if ( /^debsums: missing file (\/[^ ]+)/){
			push @{$changedFiles{'missing'}}, $1;
		}else{
			my $file = $_;
			chomp($file);
			push @{$changedFiles{'changed'}}, $file;
		}
	}
	close(PROC);
	
	return \%changedFiles;
}

sub findFilesToBeBackedUpBecauseInNoPackage{
	my $files_in_no_package = [];
	my @listOfDirs = ("/etc");
	
	# could not make the wanted sub an inner _named_ sub
	# because the variable '$files_in_no_package' will not stay shared
	# see  http://perldoc.perl.org/perldiag.html => Variable "%s" will not stay shared
	
	find({ wanted => sub {
	
		if ( -f ){
			my $package = $file_to_package_map->{$_};
			if ( !defined($package) ){
				#~ print $_,"\n";
				push @{$files_in_no_package}, $_;
			}
		}
	}
	, follow => 0, no_chdir=>1 }, @listOfDirs);

	
	return $files_in_no_package;
}

sub populateFileToPackageMap{
	
	verbose "reading index of files/packages";
	
	my $package_to_file_map = &populatePackageToFileMap;
	my $file_to_package_map = {};
	
	while (my ($package, $filesArray) = each %{$package_to_file_map}) {
		grep{
			$file_to_package_map->{$_} = $package;
		}@{$filesArray};
	}
	
	return $file_to_package_map;
	
	sub populatePackageToFileMap{
		my %package_to_file_map = ();
		
		open(DLOCATEDB,"</var/lib/dlocate/dlocatedb") || confess "$^E";
		while(<DLOCATEDB>){
			my ($package,$file) = $_ =~ /([^:]+): (.+)/;
			#print $package,"\t",$file,"\n";
			
			if (!exists($package_to_file_map{$package})){
				$package_to_file_map{$package} = [];
			}
			
			push @{$package_to_file_map{$package}}, $file;
		}
		close(DLOCATEDB);
		
		return \%package_to_file_map;
	}
}


sub parseOptionsAndGiveHelp{
	
	my $help = <<EOT;	
	-d --debug	to be verbose and print some debug infos
	-j --bzip2	(not implmented yet) use bzip2 for compression (output will be .tar.bz2)
	-h --help	show this help
	-n --dryrun	just make a dryrun, write nothing
	-v --verbose	be verbose
	-z --gzip	(not implmented yet) use gzip for compression (output will be .tar.gz)
EOT

	GetOptions (
	    'd|debug'		=> \$params->{'debug'},
	    #~ 'j|bzip2'		=> sub { $params->{'compression'} = 'bzip2'; },
	    'n|dryrun'		=> \$params->{'dryrun'},
	    'v|verbose'		=> \$params->{'verbose'},
	    #~ 'z|gzip'		=> sub { $params->{'compression'} = 'gzip'; },
	    help		=> sub { print $help; exit },
	) or confess "Try '$0 --help' for more information.\n";
}

sub debug{
	my $line = shift || confess "could not show undefined text";
	
	if ($params->{'debug'} eq 1 ){
		chomp($line);
		print "DEBUG $line\n";
	}
}

sub verbose{
	my $line = shift || confess "could not show undefined text";
	
	if ($params->{'verbose'} eq 1 ){
		chomp($line);
		print "$line\n";
	}
}

sub execute{
	my $command = shift || confess 'need command to be executed';
	
	debug 'executing '.$command;
	my $output = "";
	open(P, $command.'|') || confess $^E;
		while(<P>){
			debug $_;
			$output .= $_;
		}
	close(P);
	
	debug "output:$output";
	
	return \$output;
}

END {
    chdir $original;
}
