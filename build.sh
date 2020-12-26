#!/bin/bash -ex

cd "$(dirname "$0")"
export ROOT_DIR=$(pwd)

if [ ! -d ./src_dir ]; then
    mkdir src_dir
fi

if [ ! -d ./release ]; then
    mkdir release
fi

export SOURCE_DIR=$ROOT_DIR/src_dir
export RELEASE_DIR=$ROOT_DIR/release

function ensure_dir_with_git_branch() {
    DIR=$1
    GIT=$2
    BRANCH=$3
    if [ ! -d "./${DIR}" ]; then
        git clone $GIT $DIR
    fi
    pushd $DIR
    git fetch -f --all --tags
    if [ "$BRANCH" != "" ]; then
        git checkout -f "$BRANCH"
    fi
    git pull -f
    if [ "$BRANCH" != "" ]; then
        git checkout -f "$BRANCH"
    fi
    popd
}

cd $SOURCE_DIR
# ensure_dir_with_git_branch chromium https://chromium.googlesource.com/chromium/src.git master

export CHROMIUM_DIR=$SOURCE_DIR/chromium
export GN_DIR=$SOURCE_DIR/gn
export CLANG_SCRIPT_DIR=$CHROMIUM_DIR/tools/clang/scripts
export THIRD_PARTY_DIR=$CHROMIUM_DIR/third_party
export LLVM_BUILD_DIR=$THIRD_PARTY_DIR/llvm-build/Release+Asserts

function get_source_version() {
    export LLVM_REVISION=`grep "CLANG_REVISION = '.*'" $CLANG_SCRIPT_DIR/update.py | grep -o "'.*'" | grep -o "[^']*"`
    export GN_REVISION=`grep gn_version $CHROMIUM_DIR/DEPS | grep -o 'git_revision:\([0-9a-z]*\)' | cut -d: -f2`
}

function compile_llvm() {
    cd $THIRD_PARTY_DIR
    ensure_dir_with_git_branch llvm https://github.com/llvm/llvm-project $LLVM_REVISION
    cd $CLANG_SCRIPT_DIR
    python build.py --without-android --without-fuchsia --skip-checkout --gcc-toolchain=/opt/rh/devtoolset-7/root/usr --bootstrap --disable-asserts --pgo --thinlto || \
    python build.py --without-android --without-fuchsia --skip-checkout --gcc-toolchain=/opt/rh/devtoolset-7/root/usr --bootstrap --disable-asserts --pgo --lto-lld || \
    python build.py --without-android --without-fuchsia --skip-checkout --gcc-toolchain=/opt/rh/devtoolset-7/root/usr --bootstrap --disable-asserts --pgo
}

function compile_gn() {
    cd $SOURCE_DIR
    ensure_dir_with_git_branch gn https://gn.googlesource.com/gn $GN_REVISION
    
    export CC=/opt/rh/devtoolset-7/root/usr/bin/cc
    export CXX=/opt/rh/devtoolset-7/root/usr/bin/c++
    export LDFLAGS=-lrt
    
    cd gn
    python build/gen.py
    if ninja -C out; then
        out/gn_unittests
    else
        echo "Build Failed, skip"
        return 1
    fi
    return 0
}


cd $RELEASE_DIR
ensure_dir_with_git_branch gn git@github.com:wengzhe/google-gn-bin-centos7.git main
ensure_dir_with_git_branch clang git@github.com:wengzhe/chromium-clang-bin-centos7.git main
export GN_RELEASE_DIR=$RELEASE_DIR/gn
export CLANG_RELEASE_DIR=$RELEASE_DIR/clang


function tag_exists() {
    DIR=$1
    TAG=$2
    
    cd $DIR
    if git rev-parse $TAG; then
        return 0
    else
        return 1
    fi
}

function release_gn() {
    cd $GN_RELEASE_DIR
    mv $GN_DIR/out/gn ./
    git add .
    git commit --allow-empty -m "build.sh: r-$GN_REVISION"
    git tag r-$GN_REVISION
    git tag $CUR_TAG
    echo "build.sh: r-$GN_REVISION"
    ./gn --version
    read -p "Check GN $GN_REVISION vs $(./gn --version)"
    # git push origin --tags main:main || echo "Push failed, skip"
}

function release_clang() {
    cd $CLANG_SCRIPT_DIR
    cp $ROOT_DIR/package.py ./
    rm -rf clang-*
    python package.py
    STAMP=$(python update.py --print-revision)
    
    cd $CLANG_RELEASE_DIR
    rm -rf clang-*
    mv $CLANG_SCRIPT_DIR/clang-$STAMP* ./
    git add .
    git commit --allow-empty -m "build.sh: r-$LLVM_REVISION"
    git tag r-$LLVM_REVISION
    git tag $STAMP
    git tag $CUR_TAG
    echo "build.sh: r-$LLVM_REVISION"
    
    clang-$STAMP*/bin/clang --version
    read -p "Check Clang $STAMP vs $(ls)"
    # git push origin --tags main:main || echo "Push failed, skip"
}


for ver in {76..100}; do
    cd $CHROMIUM_DIR
    export CUR_TAG=$(git tag | grep ^${ver}.0.[0-9]*.0$ | sort | tail -1)
    if [ "$LAST_TAG" != "" ]; then
        # 需要跳过第一个没有发布的版本
        git checkout -f $CUR_TAG
        get_source_version
        # git checkout -f master
        if ! tag_exists $GN_RELEASE_DIR r-$GN_REVISION; then
            compile_gn || exit
            echo "Releasing GN"
            release_gn || exit
        elif ! tag_exists $GN_RELEASE_DIR $CUR_TAG; then
            cd $GN_RELEASE_DIR
            git tag $CUR_TAG r-$GN_REVISION
        fi
        if ! tag_exists $CLANG_RELEASE_DIR r-$LLVM_REVISION; then
            compile_llvm || exit
            echo "Releasing CLANG"
            release_clang || exit
        elif ! tag_exists $CLANG_RELEASE_DIR $CUR_TAG; then
            cd $CLANG_RELEASE_DIR
            git tag $CUR_TAG r-$LLVM_REVISION
        fi
    fi
    LAST_TAG=$CUR_TAG
done
