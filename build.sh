#!/bin/bash -ex

GIT_CHROMIUM=${GIT_CHROMIUM:-"https://chromium.googlesource.com/chromium/src.git"}
GIT_DEPOT_TOOLS=${GIT_DEPOT_TOOLS:-"https://chromium.googlesource.com/chromium/tools/depot_tools.git"}

GIT_LLVM_ORI="https://github.com/llvm/llvm-project.git"
GIT_GN_ORI="https://gn.googlesource.com/gn"
GIT_LLVM=${GIT_LLVM:-$GIT_LLVM_ORI}
GIT_GN=${GIT_GN:-$GIT_GN_ORI}

GIT_RELEASE=${GIT_RELEASE:-"false"}
GIT_GN_TARGET=${GIT_GN_TARGET:-"git@github.com:wengzhe/google-gn-bin-centos7.git"}
GIT_CLANG_TARGET=${GIT_CLANG_TARGET:-"git@github.com:wengzhe/chromium-clang-bin-centos7.git"}

export BUILD_GN=${BUILD_GN:-"false"}
export BUILD_CLANG=${BUILD_CLANG:-"false"}

BUILD_TAG_PREFIX=${BUILD_TAG_PREFIX:-""}

# TODO: clang switch - copy folder or tgz - or even split repo

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
    GIT_ORI=$4
    if [ ! -d "./${DIR}" ]; then
        git clone $GIT $DIR
    fi
    pushd $DIR
    git remote set-url origin $GIT
    git fetch -f --all --tags
    if [ "$GIT_ORI" != "" ]; then
        git remote set-url origin $GIT_ORI
        git fetch -f --all --tags
    fi
    if [ "$BRANCH" != "" ]; then
        git checkout -f "$BRANCH"
    fi
    git pull -f
    if [ "$BRANCH" != "" ]; then
        git checkout -f "$BRANCH"
    fi
    popd
}

ensure_dir_with_git_branch depot_tools $GIT_DEPOT_TOOLS master
export PATH="$PATH:$ROOT_DIR/depot_tools"

cd $SOURCE_DIR
ensure_dir_with_git_branch chromium $GIT_CHROMIUM master

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
    ensure_dir_with_git_branch llvm $GIT_LLVM $LLVM_REVISION $GIT_LLVM_ORI
    cd $CLANG_SCRIPT_DIR
    python build.py --without-android --without-fuchsia --skip-checkout --gcc-toolchain=/opt/rh/devtoolset-7/root/usr --bootstrap --disable-asserts --pgo --thinlto || \
    python build.py --without-android --without-fuchsia --skip-checkout --gcc-toolchain=/opt/rh/devtoolset-7/root/usr --bootstrap --disable-asserts --pgo --lto-lld || \
    python build.py --without-android --without-fuchsia --skip-checkout --gcc-toolchain=/opt/rh/devtoolset-7/root/usr --bootstrap --disable-asserts --pgo
}

function compile_gn() {
    cd $SOURCE_DIR
    ensure_dir_with_git_branch gn $GIT_GN $GN_REVISION $GIT_GN_ORI
    
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
ensure_dir_with_git_branch gn $GIT_GN_TARGET main
ensure_dir_with_git_branch clang $GIT_CLANG_TARGET main
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

function release_push() {
    if [ "$GIT_RELEASE" == "true" ]; then
        cd $GN_RELEASE_DIR
        git push origin --tags
        cd $CLANG_RELEASE_DIR
        git push origin --tags
    fi
}

function release_gn() {
    cd $GN_RELEASE_DIR
    mv $GN_DIR/out/gn ./
    git checkout -b r/$GN_REVISION
    git add .
    git commit --allow-empty -m "build.sh: r-$GN_REVISION"
    git tag r-$GN_REVISION
    git tag $CUR_TAG
    git push origin r/$GN_REVISION:r/$GN_REVISION --tags
    echo "build.sh: r-$GN_REVISION"
    
    check_str="Check GN $GN_REVISION vs $(./gn --version)"
    echo $check_str
    echo $check_str >> $ROOT_DIR/build.log
    
    git checkout main
    git branch -D r/$GN_REVISION
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
    git checkout -b r/$LLVM_REVISION
    git add .
    git commit --allow-empty -m "build.sh: r-$LLVM_REVISION"
    git tag r-$LLVM_REVISION
    git tag $STAMP
    git tag $CUR_TAG
    git push origin r/$LLVM_REVISION:r/$LLVM_REVISION --tags
    echo "build.sh: r-$LLVM_REVISION"
    
    check_str="Check Clang $LLVM_REVISION vs $(clang-$STAMP*/bin/clang --version) vs $STAMP"
    echo $check_str
    echo $check_str >> $ROOT_DIR/build.log
    
    git checkout main
    git branch -D r/$LLVM_REVISION
}

function build_cur_tag() {
    cd $CHROMIUM_DIR
    git checkout -f $CUR_TAG
    get_source_version
    # git checkout -f master
    if [ "$BUILD_GN" != "true" ]; then
        echo "Skip GN."
    elif ! tag_exists $GN_RELEASE_DIR r-$GN_REVISION; then
        compile_gn || exit
        echo "Releasing GN"
        release_gn || exit
    elif ! tag_exists $GN_RELEASE_DIR $CUR_TAG; then
        cd $GN_RELEASE_DIR
        git tag $CUR_TAG r-$GN_REVISION
    fi
    if [ "$BUILD_CLANG" != "true" ]; then
        echo "Skip CLANG."
    elif ! tag_exists $CLANG_RELEASE_DIR r-$LLVM_REVISION; then
        compile_llvm || exit
        echo "Releasing CLANG"
        release_clang || exit
    elif ! tag_exists $CLANG_RELEASE_DIR $CUR_TAG; then
        cd $CLANG_RELEASE_DIR
        git tag $CUR_TAG r-$LLVM_REVISION
    fi
}

if [ "$BUILD_TAG_PREFIX" != "" ]; then
    cd $CHROMIUM_DIR
    for cur_tag in `git tag | grep ^${BUILD_TAG_PREFIX}`; do
        export CUR_TAG=$cur_tag
        build_cur_tag
    done
else
    for ver in {100..77}; do
        cd $CHROMIUM_DIR
        export CUR_TAG=$(git tag | grep ^${ver}.0.[0-9]*.0$ | sort | tail -1)
        if [ "$LAST_TAG" != "" ]; then
            # 需要跳过第一个没有发布的版本
            build_cur_tag
        fi
        LAST_TAG=$CUR_TAG
    done
fi

release_push
