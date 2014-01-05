clever-backup
=============

makes a intelligent system backup


# debian package

PPA **https://launchpad.net/~lkwg82/+archive/clever-backup**

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

# steps to publish to ppa

add changelog from git commits and commit this changelog 
```
git-dch --release --git-author --commit --id-length=10
```

build source package
```
git-buildpackage -S -sa --git-tag --git-sign-tags --git-no-create-orig
```

upload (read https://help.launchpad.net/Packaging/PPA/Uploading)
```
dput ppa:lkwg82/clever-backup ../clever-backup-1_1-2ubuntu1_source.changes
```

# howto create ppa perl debian package

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
