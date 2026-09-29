# Publish x86_64 glibc XBPS packages from owned templates.
const REPOSITORY_PATH = 'x86_64-current'
const R2_BUCKET = 'void-extra'
const MAX_PACKAGE_FILES = 32
const MAX_PUBLISH_BYTES = 1_073_741_824
# Keep the repository below R2's 10 GB-month Standard free allowance.
const MAX_BUCKET_BYTES = 8_589_934_592

def published-commit []: nothing -> string {
    let key = $"($REPOSITORY_PATH)/source-sha"

    let marker = (aws --endpoint-url $env.R2_ENDPOINT s3api get-object
        --bucket $R2_BUCKET --key $key source-sha --output json | complete)

    if $marker.exit_code == 0 {
        let published = open source-sha | str trim

        if ($published | is-empty) {
            r2-fail 'R2 source-sha is empty'
        }

        return $published
    }

    let index_key = $"($REPOSITORY_PATH)/x86_64-repodata"

    let listing = (r2 ...[s3api list-objects-v2 --bucket $R2_BUCKET
        --prefix $index_key --output json] | from json)

    if ($listing.Contents? | default [] | any {|object| $object.Key == $index_key }) {
        r2-fail 'R2 has a repository but no source-sha; seed the published commit before cutover'
    }

    ''
}

def select-changes []: nothing -> nothing {
    let published = (published-commit)

    let valid = if $published == '' { false } else {
        let commit = git cat-file -e $"($published)^{commit}" | complete

        if $commit.exit_code != 0 { false } else {
            (git merge-base --is-ancestor $published HEAD | complete).exit_code == 0
        }
    }

    if $published != '' and not $valid {
        r2-fail 'R2 source-sha is not an ancestor of this commit'
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

def fetch-index []: nothing -> nothing {
    mkdir repo

    transfer-r2 ...[
        s3
        cp
        $"s3://($R2_BUCKET)/($REPOSITORY_PATH)/x86_64-repodata"
        repo/x86_64-repodata
        --only-show-errors
    ]
}

def indexed-packages []: nothing -> list<record> {
    let catalog = xbps-query -i --repository repo -s '' | complete

    if $catalog.exit_code != 0 or ($catalog.stdout | is-empty) {
        r2-fail 'Cannot read the signed R2 repository index'
    }

    let versions = ($catalog.stdout | lines |
        parse --regex '^\[[^]]+\]\s+(?<version>\S+)' | get version)

    if ($versions | is-empty) or ($versions | length) != ($catalog.stdout | lines | length) {
        r2-fail 'Cannot identify all packages in the R2 repository index'
    }

    $versions | each {|version|
        let architecture = xbps-query -i --repository repo -p architecture -S $version | str trim
        let checksum = xbps-query -i --repository repo -p filename-sha256 -S $version | str trim

        if ($architecture | is-empty) or ($checksum | is-empty) {
            r2-fail $"Incomplete R2 repository index entry: ($version)"
        }

        {filename: $"($version).($architecture).xbps", checksum: $checksum}
    }
}

def restore []: nothing -> nothing {
    fetch-index
    let prefix = $"s3://($R2_BUCKET)/($REPOSITORY_PATH)/"

    for package in (indexed-packages) {
        for asset in [$package.filename $"($package.filename).sig2"] {
            transfer-r2 ...[s3 cp $"($prefix)($asset)" $"repo/($asset)" --only-show-errors]
        }

        let actual = sha256sum $"repo/($package.filename)" | split words | first

        if $actual != $package.checksum {
            r2-fail $"R2 package does not match its signed index: ($package.filename)"
        }
    }
}

def sign []: nothing -> nothing {
    check-key

    for current in (glob 'new/*.xbps') {
        let pkgver = xbps-uhelper binpkgver $current | str trim
        let name = xbps-uhelper getpkgname $pkgver | str trim

        for old in (glob 'repo/*.xbps') {
            let oldver = xbps-uhelper binpkgver $old | str trim
            let oldname = xbps-uhelper getpkgname $oldver | str trim

            if $oldname == $name and ($old | path basename) != ($current | path basename) {
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

def transfer-r2 [...arguments: string]: nothing -> nothing {
    let output = (r2 ...$arguments)

    if ($output | is-not-empty) {
        r2-fail $"Unexpected R2 transfer output: ($output)"
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

    let prefix = $"($REPOSITORY_PATH)/"

    let listing = (r2 ...[s3api list-objects-v2 --no-paginate --bucket $R2_BUCKET
        --output json] | from json)

    if $listing.IsTruncated {
        r2-fail 'R2 repository contains too many objects to check safely'
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
        r2-fail 'R2 repository would exceed its storage safety limit'
    }

    for item in $pending {
        transfer-r2 ...[
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

    transfer-r2 ...[
        s3
        cp
        repo/x86_64-repodata
        $"s3://($R2_BUCKET)/($prefix)x86_64-repodata"
        --cache-control
        'public, max-age=60'
        --only-show-errors
    ]
}

def record-r2 []: nothing -> nothing {
    $"($env.GITHUB_SHA)\n" | save --force source-sha

    transfer-r2 ...[
        s3
        cp
        source-sha
        $"s3://($R2_BUCKET)/($REPOSITORY_PATH)/source-sha"
        --cache-control
        no-store
        --only-show-errors
    ]
}

def prune-r2 []: nothing -> nothing {
    fetch-index
    let packages = indexed-packages
    let prefix = $"($REPOSITORY_PATH)/"

    let active = ($packages | each {|package|
        [$"($prefix)($package.filename)" $"($prefix)($package.filename).sig2"]
    } | flatten)

    let listing = (r2 ...[s3api list-objects-v2 --no-paginate --bucket $R2_BUCKET
        --prefix $prefix --output json] | from json)

    if $listing.IsTruncated {
        r2-fail 'R2 repository contains too many objects to prune safely'
    }

    let objects = $listing.Contents? | default []
    let available = $objects | get Key

    if ($active | any {|key| $key not-in $available }) {
        r2-fail 'R2 repository index references missing package assets; refusing cleanup'
    }

    let index_key = $"($prefix)x86_64-repodata"
    let index_object = $objects | where Key == $index_key | first
    let cutoff = (date now) - 1day

    # Even a much older package may have become obsolete with the current index.
    if ($index_object.LastModified | into datetime) > $cutoff {
        return
    }

    mut stale = []

    for object in $objects {
        let key = $object.Key
        let filename = $key | str replace $prefix ''
        let is_package = ($filename | str ends-with .xbps) or ($filename | str ends-with .xbps.sig2)

        if $is_package and ($filename !~ /) and ($key not-in $active) and (($object.LastModified | into datetime) < $cutoff) {
            $stale ++= [$object]
        }
    }

    for object in $stale {
        r2 ...[
            s3api
            delete-object
            --bucket
            $R2_BUCKET
            --key
            $object.Key
            --output
            json
        ]

        print $"Deleted stale R2 object: ($object.Key)"
    }
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

def "main publish" []: nothing -> nothing { publish-r2 }

def "main record" []: nothing -> nothing { record-r2 }

def "main prune" []: nothing -> nothing { prune-r2 }
