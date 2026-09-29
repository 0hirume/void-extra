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
