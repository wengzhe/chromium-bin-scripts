#!/bin/bash -ex

manual=(
  llvmorg-14-init-16347-g53a51acc
  llvmorg-14-init-17086-g38e16e1c
  llvmorg-14-init-18258-g9477a308
)
for b in ${manual[@]}; do
    echo $b
    git push origin --delete `git ls-remote --tags | cut -f2 | grep $b`
    git push origin --delete `git ls-remote --heads | cut -f2 | grep $b`
done

git push origin --delete `git ls-remote --tags | cut -f2 | grep '/10'`  # 10x.*
git push origin --delete `git ls-remote --tags | cut -f2 | grep llvmorg-15`
git push origin --delete `git ls-remote --heads | cut -f2 | grep llvmorg-15`
