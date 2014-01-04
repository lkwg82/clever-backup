clever-backup
=============

makes a intelligent system backup


# debian package

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
