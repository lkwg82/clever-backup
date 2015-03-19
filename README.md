clever-backup
=============

Uses system package management to choose intelligently files to backup.

-	Records packages installed as list, to be reinstalled on restore.
-	Backups only files ...
	-	... changed from those originals in packages
	-	... or which are in none of the installed packages.

This leads to really small backups for a whole system.

## Installation
```bash
$ sudo apt-add-repository ppa:lkwg82/clever-backup
$ sudo apt-get update
$ sudo apt-get install clever-backup
```

## usage
```shell
root@...:~# clever-backup -h
```

## little benchmark

(with xubuntu livecd 13.10 in a virtualbox instance)

| method | <code>tar<sup>1</sup></code> | <code>clever-backup<sup>2</sup></code> | ratio | 
| ------ | ---------------------------- | -------------------------------------- | ----- |
| size | 2.2 GB | 0.18 GB | 12:1 |
| size (gzipped) | 0.8 GB | 0.02 GB | 40:1 |
|  |  |  |  |
| time | 02:14 Min | 04:01 Min | 1:1.8 |
| time (gzipped)| 10:29 Min | 03:17 Min| 3:1|

<sup>1</sup><code>time tar &nbsp; &nbsp; &nbsp;&nbsp;&nbsp;&nbsp;&nbsp; --exclude=/dev --exclude=/proc --exclude=/run --exclude=/sys --exclude=/tmp --exclude=/var/lib/dpkg --exclude=/var/lib/apt --exclude=/var/lib/dlocate --exclude=/var/lib/mlocate/ --exclude=/rofs --exclude=/cdrom -cf - / &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&#124; pv &#124; wc -c </code>

<sup>2</sup><code>time clever-backup --exclude=/dev --exclude=/proc --exclude=/run --exclude=/sys --exclude=/tmp --exclude=/var/lib/dpkg --exclude=/var/lib/apt --exclude=/var/lib/dlocate --exclude=/var/lib/mlocate/ --exclude=/rofs --exclude=/cdrom --action --no-compression -v -f - / &#124; pv &#124; wc -c </code>


## development

run perltidy before committing

```bash
perltidy -b clever-backup
```

---

## debian packaging

### steps to publish to ppa

add changelog from git commits and commit this changelog

```
git-dch --release --git-author --commit --id-length=10
```

build source package

```
git-buildpackage -S -sa --git-tag --git-sign-tags --git-no-create-orig
```

upload (read https://help.launchpad.net/Packaging/PPA/Uploading\)

```
dput ppa:lkwg82/clever-backup ../clever-backup-1_1-2ubuntu1_source.changes
```

PPA **https://launchpad.net/~lkwg82/+archive/clever-backup**

(on ubuntu universe repository must be activated in /etc/apt/sources.list)

### general

create package without any gpg signing (dev)

```bash
git-buildpackage --git-ignore-new -uc -us
```

list content of deb

```
dpkg -c <deb>
```

for building missing debian packages of missing perl modules

```
#!/bin/bash

set -e
#set -x;

for module in  Archive::Tar::Stream Carp::Source ;
do
	dh-make-perl --cpan $module --build;
done

dpkg -c libarch*perl*deb | grep perllocal.pod > /dev/null &&
	echo "your debhelper is too old (sorry I dont know which is appropriate enough)"
	&& exit 1
```



## howto create ppa perl debian package

```
# set some information for changelog
export DEBEMAIL='lkwg82@gmx.de'
export DEBFULLNAME='Lars K.W. Gohlke'

dh-make-perl --pkg-perl --cpan Archive::Tar::Stream
cd Archive*

# add changelog entry
dch --distribution=quantal

# create source package
debuild -S -sa -I\.git

# do lintian
lintian

# publish
dput ppa:lkwg82/clever-backup libarchive-tar-stream-perl_0.01-1_source.changes
```
