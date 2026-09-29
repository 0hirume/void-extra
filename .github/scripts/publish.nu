# Publish x86_64 glibc XBPS packages from owned templates.
const RELEASE_TAG = 'x86_64-current'

def download-published-commit []: nothing -> bool {
    let release = gh release view $RELEASE_TAG | complete

    if $release.exit_code == 0 {
        (gh release download $RELEASE_TAG --dir . --pattern source-sha | complete).exit_code == 0
    } else { false }
}

def select-changes []: nothing -> nothing {
    let published = if (download-published-commit) and ('source-sha' | path exists) {
        open source-sha | str trim
    } else { null }

    let valid = if $published == null { false } else {
        let commit = git cat-file -e $"($published)^{commit}" | complete

        if $commit.exit_code != 0 { false } else {
            (git merge-base --is-ancestor $published HEAD | complete).exit_code == 0
        }
    }

    let files = if $valid {
        git diff --name-only $published HEAD -- srcpkgs/ | lines
    } else {
        git ls-files 'srcpkgs/*' | lines
    }

    let packages = ($files | each {|file| $file | parse 'srcpkgs/{pkg}/{rest}' | get pkg | first } | uniq |
        where ($"srcpkgs/($it)/template" | path exists))

    $"packages=($packages | str join ' ')\n" | save --append $env.GITHUB_OUTPUT
}

def check-key []: nothing -> nothing {
    if ($env.XBPS_PRIVATE_KEY | is-empty) {
        error make {
            msg: 'Missing XBPS_PRIVATE_KEY secret'
            label: {
                text: 'Signing key supplied by the workflow'
                span: (metadata $env.XBPS_PRIVATE_KEY).span
            }
        }
    }
}

def bootstrap []: nothing -> nothing {
    ^cp -a owned/srcpkgs/. void-packages/srcpkgs/
    # xbps-src copies etc/conf into its chroot; the job environment is cleared.
    "XBPS_ALLOW_RESTRICTED=yes\n" | save --append void-packages/etc/conf
    chown -R builder:builder void-packages
    sudo -Eu builder bash -c 'cd void-packages && ./xbps-src binary-bootstrap'
}

def collect []: nothing -> nothing {
    mkdir new repo

    let files = ((glob 'void-packages/hostdir/binpkgs/*.xbps') ++
        (glob 'void-packages/hostdir/binpkgs/nonfree/*.xbps'))

    for pkg in ($env.PACKAGES | split row ' ') {
        mut found = false

        for file in $files {
            let pkgver = xbps-uhelper binpkgver $file | str trim
            let name = xbps-uhelper getpkgname $pkgver | str trim

            if $name == $pkg or ($name | str starts-with $"($pkg)-") {
                cp $file new/

                if $name == $pkg { $found = true }
            }
        }

        if not $found {
            error make {
                msg: $"Missing binary package: ($pkg)"
                label: {
                    text: 'Requested package'
                    span: (metadata $pkg).span
                }
            }
        }
    }
}

def restore []: nothing -> nothing {
    let release = gh release view $RELEASE_TAG | complete

    if $release.exit_code == 0 {
        gh release download $RELEASE_TAG --dir repo --pattern '*.xbps' --pattern '*.xbps.sig2'
    } else {
        gh release create $RELEASE_TAG --target $env.GITHUB_SHA --title $RELEASE_TAG --notes 'Signed x86_64 glibc XBPS packages.'
    }
}

def sign []: nothing -> nothing {
    check-key
    '' | save --force obsolete-assets

    for current in (glob 'new/*.xbps') {
        let pkgver = xbps-uhelper binpkgver $current | str trim
        let name = xbps-uhelper getpkgname $pkgver | str trim

        for old in (glob 'repo/*.xbps') {
            let oldver = xbps-uhelper binpkgver $old | str trim
            let oldname = xbps-uhelper getpkgname $oldver | str trim

            if $oldname == $name and ($old | path basename) != ($current | path basename) {
                $"($old | path basename)\n($old | path basename).sig2\n"
                | save --append obsolete-assets

                rm --force $old $"($old).sig2"
            }
        }
    }

    for pkg in (glob 'new/*.xbps') { cp $pkg repo/ }

    let key = (^mktemp | str trim)

    try {
        ($env.XBPS_PRIVATE_KEY + "\n") | save --force $key
        chmod 600 $key

        # xbps-rindex skips existing signatures, including from an old key.
        for sig in (glob 'repo/*.xbps.sig2') { rm $sig }

        for pkg in (glob 'repo/*.xbps') {
            xbps-rindex --sign-pkg --privkey $key $pkg
        }

        xbps-rindex -a ...(glob 'repo/*.xbps')
        xbps-rindex --sign --signedby void-extra --privkey $key repo/

        let index = 'repo/x86_64-repodata'

        if not ($index | path exists) {
            error make {
                msg: 'Missing signed repository index'
                label: {
                    text: 'Expected index path'
                    span: (metadata $index).span
                }
            }
        }
    } catch {|err|
        rm --force $key
        error make $err
    }

    rm --force $key
}

const R2_BUCKET = 'void-extra'
const MAX_PACKAGE_FILES = 32
const MAX_PUBLISH_BYTES = 1_073_741_824
# Keep the mirror below R2's 10 GB-month Standard free allowance.
const MAX_BUCKET_BYTES = 8_589_934_592

def r2-fail [message: string]: nothing -> error {
    error make {
        msg: $message
        label: {
            text: 'R2 publisher'
            span: (metadata $message).span
        }
    }
}

def r2 [...arguments: string]: nothing -> string {
    let result = aws --endpoint-url $env.R2_ENDPOINT ...$arguments | complete

    if $result.exit_code != 0 {
        r2-fail $"R2 request failed: ($result.stderr | str trim)"
    }

    $result.stdout
}

def upload-r2 [...arguments: string]: nothing -> nothing {
    let output = (r2 ...$arguments)

    if ($output | is-not-empty) {
        r2-fail $"Unexpected R2 upload output: ($output)"
    }
}

def publish-r2 []: nothing -> nothing {
    let files = ((glob 'repo/*.xbps') ++ (glob 'repo/*.xbps.sig2'))

    if ($files | is-empty) {
        r2-fail 'R2 publish has no package files'
    }

    if ($files | length) > $MAX_PACKAGE_FILES {
        r2-fail 'R2 publish exceeds the package file limit'
    }

    let local_bytes = $files | each {|file| (ls $file | get size | first | into int) } | math sum

    if $local_bytes > $MAX_PUBLISH_BYTES {
        r2-fail 'R2 publish exceeds the package size limit'
    }

    let prefix = $"($RELEASE_TAG)/"

    let listing = (r2 ...[s3api list-objects-v2 --no-paginate --bucket $R2_BUCKET
        --output json] | from json)

    if $listing.IsTruncated {
        r2-fail 'R2 mirror contains too many objects to check safely'
    }

    let objects = $listing.Contents? | default []

    let stored_bytes = if ($objects | is-empty) { 0 } else {
        $objects | get Size | math sum
    }

    mut pending = []

    for file in $files {
        let key = $"($prefix)($file | path basename)"
        let digest = sha256sum $file | split words | first
        let existing = $objects | where Key == $key

        if ($existing | is-not-empty) {
            let metadata = (r2 ...[s3api head-object --bucket $R2_BUCKET --key $key
                --output json] | from json)

            if $metadata.Metadata.sha256? != $digest {
                r2-fail $"R2 object changed without a new package version: ($key)"
            }
        } else {
            $pending ++= [
                {file: $file, key: $key, digest: $digest}
            ]
        }
    }

    let upload_bytes = if ($pending | is-empty) { 0 } else {
        $pending | each {|item| (ls $item.file | get size | first | into int) } | math sum
    }

    if ($stored_bytes + $upload_bytes) > $MAX_BUCKET_BYTES {
        r2-fail 'R2 mirror would exceed its storage safety limit'
    }

    for item in $pending {
        upload-r2 ...[
            s3
            cp
            $item.file
            $"s3://($R2_BUCKET)/($item.key)"
            --cache-control
            'public, max-age=86400'
            --metadata
            $"sha256=($item.digest)"
            --only-show-errors
        ]
    }

    upload-r2 ...[
        s3
        cp
        repo/x86_64-repodata
        $"s3://($R2_BUCKET)/($prefix)x86_64-repodata"
        --cache-control
        'public, max-age=60'
        --only-show-errors
    ]
}

def mirror-r2 []: nothing -> nothing {
    if not ('repo/x86_64-repodata' | path exists) {
        let index_key = $"($RELEASE_TAG)/x86_64-repodata"

        let listing = (r2 ...[s3api list-objects-v2 --no-paginate --bucket $R2_BUCKET
            --prefix $index_key --output json] | from json)

        if ($listing.Contents? | default [] | any {|object| $object.Key == $index_key }) {
            return
        }

        mkdir repo

        let release = (gh release download $RELEASE_TAG --dir repo --pattern '*.xbps'
            --pattern '*.xbps.sig2' --pattern x86_64-repodata | complete)

        if $release.exit_code != 0 {
            r2-fail $"Could not restore signed release: ($release.stderr | str trim)"
        }
    }

    publish-r2
}

def prepare-publish []: nothing -> list<string> {
    let obsolete = open obsolete-assets | lines
    $"($env.GITHUB_SHA)\n" | save --force source-sha
    $obsolete
}

def publish []: nothing -> nothing {
    let obsolete = (prepare-publish)
    let packages = (glob 'repo/*.xbps')
    let signatures = (glob 'repo/*.xbps.sig2')
    gh release upload $RELEASE_TAG ...$packages ...$signatures --clobber
    gh release upload $RELEASE_TAG repo/x86_64-repodata --clobber

    for asset in $obsolete {
        gh release delete-asset $RELEASE_TAG $asset --yes
    }

    gh release upload $RELEASE_TAG source-sha --clobber
}

def main []: nothing -> nothing {
    print --stderr 'Specify a publish phase'
    exit 2
}

def "main changes" []: nothing -> nothing { select-changes }

def "main check-key" []: nothing -> nothing { check-key }

def "main bootstrap" []: nothing -> nothing { bootstrap }

def "main build" []: nothing -> nothing {
    for pkg in ($env.PACKAGES | split row ' ') {
        sudo -Eu builder bash -c 'cd void-packages && ./xbps-src pkg "$1"' _ $pkg
    }
}

def "main collect" []: nothing -> nothing { collect }

def "main restore" []: nothing -> nothing { restore }

def "main sign" []: nothing -> nothing { sign }

def "main publish" []: nothing -> nothing { publish }

def "main mirror-r2" []: nothing -> nothing { mirror-r2 }
