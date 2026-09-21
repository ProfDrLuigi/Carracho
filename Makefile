.PHONY: all native server tracker native-werror debs deb-server deb-tracker swift-tests c-tests macos-build release-check clean

all: native

native: server tracker

server:
	./ServerLinux/build.sh

tracker:
	./TrackerLinux/build.sh

native-werror:
	EXTRA_CFLAGS=-Werror ./ServerLinux/build.sh
	EXTRA_CFLAGS=-Werror ./TrackerLinux/build.sh

debs:
	./build-debs.sh all

deb-server:
	./build-debs.sh server

deb-tracker:
	./build-debs.sh tracker

swift-tests:
	Analysis/tests/run_all.zsh

c-tests:
	Analysis/tests/run_c_linux_server_all.zsh

macos-build:
	xcodebuild -project Carracho.xcodeproj -scheme Carracho -configuration Debug CODE_SIGNING_ALLOWED=NO build

release-check: native-werror swift-tests c-tests macos-build

clean:
	rm -rf .build
