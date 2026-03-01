SHOUT_REPO    := ../shout
SBCL_VERSION  := 2.6.2
SBCL_ARCH     := x86-64
SBCL_OS       := linux
SBCL_TARBALL  := sbcl-$(SBCL_VERSION)-$(SBCL_ARCH)-$(SBCL_OS)-binary.tar.bz2
SBCL_URL      := https://github.com/roswell/sbcl_bin/releases/download/$(SBCL_VERSION)/$(SBCL_TARBALL)

default: blobs

# Download Roswell SBCL binary and add as blob
sbcl-blob:
	@echo "Downloading SBCL $(SBCL_VERSION) for $(SBCL_ARCH)-$(SBCL_OS)..."
	curl -L -o /tmp/$(SBCL_TARBALL) $(SBCL_URL)
	bosh add-blob /tmp/$(SBCL_TARBALL) sbcl/$(SBCL_TARBALL)
	rm /tmp/$(SBCL_TARBALL)

# Create shout source tarball from git archive and add as blob
shout-blob:
	@echo "Creating shout source tarball from $(SHOUT_REPO)..."
	cd $(SHOUT_REPO) && git archive --format=tar.gz --prefix=shout/ -o /tmp/shout-src.tar.gz HEAD
	bosh add-blob /tmp/shout-src.tar.gz shout/shout-src.tar.gz
	rm /tmp/shout-src.tar.gz

# Create/update both blobs
blobs: sbcl-blob shout-blob

# Upload blobs to the remote blobstore (S3)
upload-blobs:
	bosh upload-blobs

# Create a BOSH dev release
release:
	bosh create-release --force

.PHONY: default sbcl-blob shout-blob blobs upload-blobs release
