# Path to a checkout of github.com/cloudfoundry-community/shout (the Go source).
SHOUT_REPO    ?= ../shout
# Semantic version stamped into the Shout! binary.
SHOUT_VERSION ?= 0.1.0-dev

default: blobs

# Build the Shout! Go server as a static linux/amd64 binary and add it as a blob
shout-blob:
	SHOUT_REPO="$(SHOUT_REPO)" SHOUT_VERSION="$(SHOUT_VERSION)" ./scripts/build-shout-blob

# Create/update every blob
blobs: shout-blob

# Upload blobs to the remote blobstore (S3)
upload-blobs:
	bosh upload-blobs

# Run the job template tests
spec:
	bundle exec rspec

# Create a BOSH dev release
release:
	bosh create-release --force

.PHONY: default shout-blob blobs upload-blobs spec release
