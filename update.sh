#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

versions=( "$@" )
if [ ${#versions[@]} -eq 0 ]; then
	versions=( */ )
fi
versions=( "${versions[@]%/}" )

defaultFrom='ubuntu:bionic'
declare -A froms=(
	[3.6]='ubuntu:xenial'
	[4.0]='ubuntu:xenial'
)

declare -A fromToCommunityVersionsTarget=(
	[ubuntu:bionic]='ubuntu1804'
	[ubuntu:xenial]='ubuntu1604'
)

declare -A dpkgArchToBashbrew=(
	[amd64]='amd64'
	[armel]='arm32v5'
	[armhf]='arm32v7'
	[arm64]='arm64v8'
	[i386]='i386'
	[ppc64el]='ppc64le'
	[s390x]='s390x'
)

# https://github.com/mkevenaar/chocolatey-packages/blob/8c38398f695e86c55793ee9d61f4e541a25ce0be/automatic/mongodb.install/update.ps1#L15-L31
communityVersions="$(
	curl -fsSL 'https://www.mongodb.com/download-center/community' \
		| grep -oiE '"server-data">window[.]__serverData = {(.+?)}<' \
		| cut -d= -f2- | cut -d'<' -f1 \
		| jq -c '.community.versions[]'
)"

travisEnv=
appveyorEnv=
for version in "${versions[@]}"; do
	rcVersion="${version%-rc}"
	major="$rcVersion"
	rcJqNot='| not'
	if [ "$rcVersion" != "$version" ]; then
		rcJqNot=
		major='testing'
	fi

	from="${froms[$version]:-$defaultFrom}"
	distro="${from%%:*}" # "debian", "ubuntu"
	suite="${from#$distro:}" # "jessie-slim", "xenial"
	suite="${suite%-slim}" # "jessie", "xenial"

	downloads="$(
		jq -c --arg rcVersion "$rcVersion" '
			select(
				(.version | startswith($rcVersion + "."))
				and (.version | contains("-rc") '"$rcJqNot"')
			)
			| .version as $version
			| .downloads[]
			| select(.arch == "x86_64")
			| .version = $version
		' <<<"$communityVersions"
	)"
	versions="$(
		jq -r --arg target "${fromToCommunityVersionsTarget[$from]}" '
			select(.edition == "targeted" and .target // "" == $target)
			| .version
		' <<<"$downloads"
	)"
	windowsDownloads="$(
		jq -c '
			select(
				.edition == "base"
				and (.target // "" | test("^windows(_x86_64-(2008plus-ssl|2012plus))?$"))
			)
		' <<<"$downloads"
	)"
	windowsVersions="$(
		jq -r '.version' <<<"$windowsDownloads"
	)"
	commonVersions="$(
		comm -12 \
			<(sort -u <<<"$versions") \
			<(sort -u <<<"$windowsVersions")
	)"
	fullVersion="$(sort -V <<< "$commonVersions" | tail -1)"

	if [ -z "$fullVersion" ]; then
		echo >&2 "error: failed to find full version for $version"
		exit 1
	fi

	echo "$version: $fullVersion"

	component='multiverse'
	if [ "$distro" = 'debian' ]; then
		component='main'
	fi
	repoUrlBase="https://repo.mongodb.org/apt/$distro/dists/$suite/mongodb-org/$major/$component"

	_arch_has_version() {
		local arch="$1"; shift
		local version="$1"; shift
		curl -fsSL "$repoUrlBase/binary-$arch/Packages.gz" 2>/dev/null \
			| gunzip 2>/dev/null \
			| awk -F ': ' -v version="$version" '
				BEGIN { ret = 1 }
				$1 == "Package" { pkg = $2 }
				pkg ~ /^mongodb-(org(-unstable)?|10gen)$/ && $1 == "Version" && $2 == version { print pkg; ret = 0; last }
				END { exit(ret) }
			'
	}

	arches=()
	packageName=
	for dpkgArch in "${!dpkgArchToBashbrew[@]}"; do
		bashbrewArch="${dpkgArchToBashbrew[$dpkgArch]}"
		if archPackageName="$(_arch_has_version "$dpkgArch" "$fullVersion")"; then
			if [ -z "$packageName" ]; then
				packageName="$archPackageName"
			elif [ "$archPackageName" != "$packageName" ]; then
				echo >&2 "error: package name for $dpkgArch ($archPackageName) does not match other arches ($packageName)"
				exit 1
			fi
			arches+=( "$bashbrewArch" )
		fi
	done
	sortedArches="$(xargs -n1 <<<"${arches[*]}" | sort | xargs)"
	if [ -z "$sortedArches" ]; then
		echo >&2 "error: version $version is missing $distro ($suite) packages!"
		exit 1
	fi

	echo "- $sortedArches"

	if [ "$major" != 'testing' ]; then
		gpgKeyVersion="$rcVersion"
		minor="${rcVersion#*.}" # "4.3" -> "3"
		if [ "$(( minor % 2 ))" = 1 ]; then
			gpgKeyVersion="${rcVersion%.*}.$(( minor + 1 ))"
		fi
		gpgKeys="$(grep "^$gpgKeyVersion:" gpg-keys.txt | cut -d: -f2)"
	else
		# the "testing" repository (used for RCs) could be signed by any of the GPG keys used by the project
		gpgKeys="$(grep -E '^[0-9.]+:' gpg-keys.txt | cut -d: -f2 | xargs)"
	fi

	sed -r \
		-e 's/^(ENV MONGO_MAJOR) .*/\1 '"$major"'/' \
		-e 's/^(ENV MONGO_VERSION) .*/\1 '"$fullVersion"'/' \
		-e 's/^(ARG MONGO_PACKAGE)=.*/\1='"$packageName"'/' \
		-e 's/^(FROM) .*/\1 '"$from"'/' \
		-e 's/%%DISTRO%%/'"$distro"'/' \
		-e 's/%%SUITE%%/'"$suite"'/' \
		-e 's/%%COMPONENT%%/'"$component"'/' \
		-e 's!%%ARCHES%%!'"$sortedArches"'!g' \
		-e 's/^(ENV GPG_KEYS) .*/\1 '"$gpgKeys"'/' \
		Dockerfile-linux.template \
		> "$version/Dockerfile"

	cp -a docker-entrypoint.sh "$version/"

	windowsMsi="$(
		jq -r --arg version "$fullVersion" '
			select(.version == $version)
			| .msi
		' <<<"$windowsDownloads" | head -1
	)"
	[ -n "$windowsMsi" ]

	# 4.3 doesn't seem to have a sha256 file (403 forbidden), so this has to be optional :(
	windowsSha256="$(curl -fsSL "$windowsMsi.sha256" | cut -d' ' -f1 || :)"

	for winVariant in \
		windowsservercore-{1809,ltsc2016} \
	; do
		mkdir -p "$version/windows/$winVariant"

		sed -r \
			-e 's/^(ENV MONGO_VERSION) .*/\1 '"$fullVersion"'/' \
			-e 's!^(ENV MONGO_DOWNLOAD_URL) .*!\1 '"$windowsMsi"'!' \
			-e 's/^(ENV MONGO_DOWNLOAD_SHA256)=.*/\1='"$windowsSha256"'/' \
			-e 's!^(FROM .+):.+!\1:'"${winVariant#*-}"'!' \
			Dockerfile-windows.template \
			> "$version/windows/$winVariant/Dockerfile"

		case "$winVariant" in
			# https://www.appveyor.com/docs/windows-images-software/
			*-1809)
				appveyorEnv='\n    - version: '"$version"'\n      variant: '"$winVariant"'\n      APPVEYOR_BUILD_WORKER_IMAGE: Visual Studio 2019'"$appveyorEnv"
				;;
			*-ltsc2016)
				appveyorEnv='\n    - version: '"$version"'\n      variant: '"$winVariant"'\n      APPVEYOR_BUILD_WORKER_IMAGE: Visual Studio 2017'"$appveyorEnv"
				;;
		esac
	done

	travisEnv='\n    - os: linux\n      env: VERSION='"$version$travisEnv"
done

travis="$(awk -v 'RS=\n\n' '$1 == "matrix:" { $0 = "matrix:\n  include:'"$travisEnv"'" } { printf "%s%s", $0, RS }' .travis.yml)"
echo "$travis" > .travis.yml

appveyor="$(awk -v 'RS=\n\n' '$1 == "environment:" { $0 = "environment:\n  matrix:'"$appveyorEnv"'" } { printf "%s%s", $0, RS }' .appveyor.yml)"
echo "$appveyor" > .appveyor.yml
