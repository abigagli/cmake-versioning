# cmake-versioning

A deploy version counter for CMake projects, with **no server to run**.

The deploy version is a human-controlled progressive number baked into the firmware and
into the image filename — `GMAPP_00129_<crc>_<size>.bin`. It has to be the same number for
everyone, on every machine, forever. This repository keeps it in the one place every
developer already shares and already authenticates against: **the project's own git
remote**, as tags.

There is nothing to deploy, nothing to pay for, no credential to hand out, and no service
that can be down when you need to ship.

- [A. How it works](#a-how-it-works)
- [B. Adopting it in a project](#b-adopting-it-in-a-project)
- [C. Escape hatches](#c-escape-hatches)
- [D. Runbook](#d-runbook)
- [Reference](#reference)

---

## A. How it works

### The idea

Allocating a shared counter safely is a distributed-systems problem: two developers must
never get the same number. The usual answer is a server with an atomic
compare-and-swap.

Git already has one:

```console
$ git push origin deploy/1.00130
 ! [rejected]  deploy/1.00130 -> deploy/1.00130 (already exists)
```

**A tag push either creates the tag or fails.** The remote decides, atomically, with no
coordination protocol. That single fact is the whole design. Everything else is
bookkeeping around it.

Because the counter *is* the tags:

- it is reachable from anywhere over the public internet;
- it is authenticated by the SSH key you already push with;
- it has a management UI — the repository's **Tags** page;
- every allocation is audited, with an author and a date, because deploy tags are
  annotated;
- a version is permanently bound to the exact commit that produced the image.

### The two tag namespaces

| Tag | Created by | Kind | Meaning |
|---|---|---|---|
| `deploy/<major>.<minor>` | the build, automatically | annotated | This version **was deployed**, from this exact commit. **Exclusive**: the number is spent, move past it. |
| `deploy-next/<major>.<minor>` | a human | lightweight | The version the next deployed image **will** carry. **Inclusive**: this is the number to use. |

```
next_minor = max( max(minor of deploy/*) + 1 ,
                  max(minor of deploy-next/*) )
major      = major of the highest-sorting tag
```

With no tags at all, the answer is `1.00001`.

Note the asymmetry — it is deliberate, and it is why the namespace is called `-next` and
not `-floor`. "Set the next version to 200" should give you exactly 200, not 201.

Two consequences fall out of the `max(...)` above:

- **The counter cannot move backwards.** A lower `deploy-next` tag is simply ignored,
  because `max(deploy) + 1` wins. `set-next` therefore *refuses* a lower value rather than
  pushing a tag that would silently do nothing. This is a safety property: reusing a
  number would let two different binaries claim the same image filename.
- **`deploy-next` tags accumulate**, and only the highest matters. Nothing is ever
  rewritten or deleted, so the whole history stays readable.

### The minor never resets

The image filename carries **only the minor** — `GMAPP_00129_...`, from
`printf "%05d"`. If bumping the major restarted the minor, `GMAPP_00001` would collide
with images from years ago.

So the minor is a globally monotonic counter and **the major is a human-facing label**.
Going from `1.00499` to major 2 gives you `2.00500`, not `2.00001`.

### One version, three renderings

| Rendering | Example | Used for |
|---|---|---|
| canonical | `1.00129` | git tags |
| display | `1.129` | the firmware string, `VER=1.129` |
| padded minor | `00129` | the image filename |

The display form is unpadded because that is what the pre-tag scheme produced, and
anything parsing `VER=` must keep working. All three are computed once, by
`deploy_version.sh`, and written to the state file — so the shell and CMake can never
disagree about what version this build is.

Input is normalised: `1.129` and `1.00129` mean the same thing everywhere you type a
version.

### What happens during a build

```
cmake --build BUILD --target deploy_versioned_<project>.elf
 │
 ├─ _generate_deploy_version → deploy_version.sh allocate
 │     1. check the repository is in a fit state to deploy from
 │     2. one `git ls-remote` to read the counter
 │     3. if HEAD is already deployed, reuse that version (idempotent)
 │     4. write BUILD/allocated_deploy_version.txt
 │     5. bake the version into version_deploy.c
 │     ✗ on any failure the build stops. Nothing has been consumed.
 │
 ├─ compile and link → objcopy → <project>.bin
 │
 └─ deploy_versioned_<project>.elf
       1. deploy_version.sh commit   ← pushes the tag. THIS is the allocation.
       2. the project's CRC/naming script copies the image into images/<config>/
       ✗ if the tag push is rejected, step 2 never runs and no image is produced.
```

**A version is consumed only by a successful deploy.** Building the versioned target
without deploying — to see what version you would get, or just to compile it — reads the
counter and changes nothing. An aborted build costs nothing.

### There is no local state

`deploy_version.sh` computes everything from a single `git ls-remote` against the remote.
**Local tags are never consulted.** There is no `git fetch` to forget, no `--prune-tags`
that could delete a colleague's tag, and no stale local tag that could inflate the
counter. If two machines disagree, they are both wrong and the remote is right.

The only file written is `BUILD/allocated_deploy_version.txt`, and it is **build scratch,
not state**. `rm -rf BUILD` is safe: the next build recomputes the same answer from the
remote.

That is worth dwelling on, because the file it replaces sat in the same directory and
looked much the same. `next_deploy_version.txt` *was* the counter, so nuking the build
directory silently reset you to `1.0` — the bug this whole design exists to remove. The new
file is disposable. Same place, opposite meaning.

(One exception, which is not about the counter: an **unclaimed override build**. See
[if the state file is lost](#if-the-state-file-is-lost).)

### The state file

`allocate` decides the version once and records it here, so that the four things that need
it cannot disagree:

| Reader | Uses |
|---|---|
| `generate_deploy_version.cmake` | `VERSION_DISPLAY` → the string baked into the firmware |
| `deploy_version.sh commit` | `VERSION`, `DIRTY`, `OVERRIDE` → whether and what to tag |
| the project's deploy script | `MINOR` → filename; `DIRTY`/`OVERRIDE` → subfolder |
| `deploy_version.sh claim` | `VERSION`, `OVERRIDE`, `TREE_CLEAN`, `COMMIT` |

It is valid shell, meant to be `source`d:

```sh
VERSION=1.00129          # canonical - what the git tag is called
VERSION_DISPLAY=1.129    # what goes in the firmware, plus any hatch suffix
MAJOR=1
MINOR=00129              # zero-padded - use this for the filename, as-is
DIRTY=0                  # 1 if built with DEPLOY_VERSION_ALLOW_DIRTY
OVERRIDE=0               # 1 if built with DEPLOY_VERSION_OVERRIDE
REUSED=0                 # 1 if HEAD was already deployed under this version
TREE_CLEAN=1             # was the worktree clean when this was allocated
COMMIT=aa1516c...        # HEAD at allocation time
```

> **Use `$MINOR` directly in filenames. Do not re-`printf "%05d"` it** — shell `printf`
> reads a leading-zero string as octal, and `00129` is not valid octal.

### If the state file is lost

For an ordinary build, losing it costs nothing: `allocate` runs again and reads the same
answer off the remote.

**The exception is an override build you have not yet claimed.** No tag was pushed for it —
that is what makes it an emergency hatch — so this file is the *only* record of which
version that image carried and which commit it came from. Without it, `claim` cannot work.

It is easier to lose than it looks. Every `allocate` writes the **same path**, so it is not
only `rm -rf BUILD` that destroys it:

```console
$ DEPLOY_VERSION_OVERRIDE=1.42 cmake --build BUILD --target deploy_versioned_x.elf
$ cmake --build BUILD --target versioned_x.elf     # innocuous - just a rebuild
$ deploy_version.sh claim --state BUILD/allocated_deploy_version.txt
deploy_version.sh: ERROR: state file '...' is not from an override build
```

**So claim an override build promptly** — as soon as you are back online, before building
anything else.

If it is already gone, the version is still recoverable from the image itself: the filename
(`GMAPP_00042_...`) and the firmware string (`VER=1.42-x`) both carry it. You cannot claim
it any more, but you can stop the number being handed out again:

```sh
./cmake/versioning/set_next_deploy_version.sh 1.43
```

That loses the audit trail — nothing will record which commit produced that image — while
keeping the guarantee that two binaries never share a version.

---

## B. Adopting it in a project

### Prerequisites

1. **A git remote named `origin`** that everyone can push tags to. Tag creation is the
   allocation mechanism, so read-only access is not enough.
2. **Network access at deploy time.** The counter lives on the remote. (For when you do
   not have it, see [`DEPLOY_VERSION_OVERRIDE`](#deploy_version_override--emergency).)
3. **bash**, and standard `awk` / `sed` / `sort -V`. Ships with macOS and Linux; on
   Windows, git-bash must be on `PATH`.
4. **A CMake project** that already separates a plain target from a *versioned* one — the
   versioned target compiles the generated `version_deploy.c`, the plain one does not.
5. **A deploy script** that produces the final image. This repository does not name or
   checksum images; that stays project-specific.

### Adding the submodule

This repository is designed to be mounted **exactly where the old `cmake/versioning/`
directory was**, so `CMakeLists.txt` needs no changes at all.

> **You must remove the existing directory from the git *index* first.** A path in a git
> tree is exactly one entry with one mode: a submodule is a `160000` gitlink, a directory
> is a tree of `100644` blobs. They cannot coexist at one path, so git refuses rather than
> merging. `rm -rf` is **not** enough — `git submodule add` validates against the index:
>
> ```
> fatal: 'cmake/versioning' already exists in the index
> ```

```sh
# 1. remove the old directory from the index AND the worktree
git rm -r cmake/versioning

# 2. mount this repository in its place
git submodule add git@github.com:abigagli/cmake-versioning.git cmake/versioning

# 3. both stagings go in ONE commit
git commit
```

Use the SSH URL if the project's other submodules use SSH, so no new credential is needed.

**Tell your colleagues** in that commit message. When they pull, git leaves
`cmake/versioning/` **empty** rather than populating it, and their build breaks
confusingly until they run:

```sh
git submodule update --init --recursive
```

### Wiring it into CMakeLists.txt

If you are adopting from the previous layout, this is already done and unchanged:

```cmake
include(cmake/versioning/targets.cmake)

# version.h must be on the include path for sources that call deploy_version()
target_include_directories(application PUBLIC ${CMAKE_SOURCE_DIR}/cmake/versioning)

# the versioned target compiles the generated file; the plain one does not
add_executable(versioned_${PROJECT_NAME}.elf EXCLUDE_FROM_ALL
               ${LINKER_SCRIPT} $<TARGET_OBJECTS:application> version_deploy.c)

ADD_DEPLOY_TARGET_FOR(
  versioned_${PROJECT_NAME}.elf          # target to deploy
  ${BIN_FILE}                            # the file to publish
  GMAPP                                  # image basename
  ${CMAKE_SOURCE_DIR}/images/${CURRENT_BUILD_TYPE}
  ${CMAKE_SOURCE_DIR}/scripts/deploy_with_crc_and_version.sh)
```

Keep `versioned_*.elf` as `EXCLUDE_FROM_ALL`, so ordinary builds never touch the network.

### What the project's deploy script must do

`ADD_DEPLOY_TARGET_FOR` calls it with four arguments; the fourth is the state file:

```sh
DEPLOY_FOLDER=$1
ORIGIN_FILE=$2
IMAGE_BASENAME=$3
STATE_FILE=$4

. "$STATE_FILE"          # VERSION, VERSION_DISPLAY, MINOR, DIRTY, OVERRIDE, ...

# keep un-tagged images out of the released set
if   [ "$OVERRIDE" != "0" ]; then DEPLOY_FOLDER="$DEPLOY_FOLDER/override"
elif [ "$DIRTY"    != "0" ]; then DEPLOY_FOLDER="$DEPLOY_FOLDER/dirty"
fi
mkdir -p "$DEPLOY_FOLDER"

# $MINOR is already zero-padded - do not printf it again
cp -p "$ORIGIN_FILE" "$DEPLOY_FOLDER/${IMAGE_BASENAME}_${MINOR}_${CHECKSUM}_${SIZE}.bin"
```

By the time this runs, the version has already been tagged. If the tag push failed, the
build stopped and this script was never reached.

### Seeding the counter

If the project already had a version counter, start where it left off:

```sh
./cmake/versioning/set_next_deploy_version.sh 1.129
```

Otherwise the first deploy is `1.00001`.

### Recommended hardening

Add a GitHub **ruleset** on the tag pattern `deploy/**` that forbids deletion. The counter
then becomes provably append-only: a version can never be silently freed and reissued to a
different binary. Leave `deploy-next/**` unprotected.

Without it, the boundary is guarded by attention alone — and the two deletions sit one
character apart. Removing a *superseded* `deploy-next/*` tag is a harmless no-op; removing
a `deploy/*` tag frees a number that a shipped binary already claims, so the next deploy
mints a second, different image with the same name.

### Migrating a project that already has the old scaffolding

If the project carries a local `cmake/versioning/` directory and a
`next_deploy_version.txt`, this replaces both. Work on a branch.

**1. Survey first.** Record what you must preserve:

```sh
grep -in "add_deploy_target_for" CMakeLists.txt     # -i matters, see below
find . -name next_deploy_version.txt -not -path "./.git/*"
ls images/*/ | tail                                  # the high-water mark
git config -f .gitmodules --get-regexp path          # other submodules
```

> **Match the macro case-insensitively.** Projects call it both as
> `ADD_DEPLOY_TARGET_FOR` and `add_deploy_target_for` — CMake commands are
> case-insensitive, so both work. A case-sensitive search will report projects as "not
> deploying" while deployed images sit in their `images/` directory.

**2. Swap the directory for the submodule** — see [Adding the submodule](#adding-the-submodule).
Mount it at `cmake/versioning`, the same path, and `CMakeLists.txt` needs no edits at all.

**3. Adapt the project's deploy script.** This is the only file that genuinely differs
between projects — checksum tooling and toolchain paths vary. The versioning portion is
always the same three changes:

```diff
-VERSION_FILE=$4
-next_minor=$(cut -d ';' -f 2 < "$VERSION_FILE")
-deployed_minor=$((next_minor - 1))
-version_formatted=$(printf "%05d" "$deployed_minor")
+STATE_FILE=$4
+. "$STATE_FILE"
+version_formatted=$MINOR
```

plus the `dirty/` and `override/` subfolder branches from
[What the project's deploy script must do](#what-the-projects-deploy-script-must-do).

**4. Confirm the build directory is gitignored.** The state file is written there, and an
untracked file inside the repository makes every deploy fail the clean-tree check. Build
directories are named inconsistently across projects — `BUILD/`, `cmake-build-debug/`,
`<project>_cmake/build/`:

```sh
git check-ignore -v <builddir>/next_deploy_version.txt
```

**5. Seed the counter** at the value the old file held, or one past the highest image:

```sh
./cmake/versioning/set_next_deploy_version.sh 1.128
```

Read the old file carefully — `1;128` means the *next* version is 128, not 129. And check
the major: not every project is on 1.

**6. Verify, in this order**, before deploying for real:

```sh
cmake --preset <configure-preset>                       # must need no CMakeLists edits
cmake --build <dir> --target deploy_version_list        # reads the counter
cmake --build <dir> --target versioned_<proj>  # twice: version must not advance
DEPLOY_VERSION_ALLOW_DIRTY=1 cmake --build <dir> --target deploy_<versioned target>
strings images/*/dirty/*.bin | grep VER=                # format unchanged?
```

Only then deploy for real, on a clean tree with HEAD pushed.

**7. Merging.** Once the submodule is in place, `git switch` between a branch that has it
and one that still tracks `cmake/versioning/*` as files **fails** — one path cannot be both
a gitlink and a tree. To squash-merge without fighting it, build the commit directly:

```sh
GIT_INDEX_FILE=/tmp/sq git read-tree <branch>
GIT_INDEX_FILE=/tmp/sq git write-tree                  # -> TREE
git commit-tree TREE -p main -m "..."                  # -> COMMIT
git branch -f main COMMIT
```

No checkout, no `submodule deinit`, no working-tree churn.

---

## C. Escape hatches

Both are environment variables. Both produce an image that is **not tagged**, is **marked
in the firmware version string**, and lands in **its own subfolder** so it can never be
mistaken for a released image.

| | `DEPLOY_VERSION_ALLOW_DIRTY=1` | `DEPLOY_VERSION_OVERRIDE=<version>` |
|---|---|---|
| Situation | Iterating; the tree is not commit-worthy yet | Offline, or an exact number is required |
| Network | used | **none at all** |
| Repository checks | skipped | skipped |
| Version | computed normally | exactly what you asked for |
| Firmware string | `VER=1.130-dirty` | `VER=1.42-x` |
| Image folder | `images/<cfg>/dirty/` | `images/<cfg>/override/` |
| Consumes a number | no | no |
| Reconcilable afterwards | no — just rebuild cleanly | **yes**, with `claim` |

### `DEPLOY_VERSION_ALLOW_DIRTY` — development

Normal deploys require a clean, pushed tree, submodules included. That is exactly right for
something you might ship, and exactly wrong while you are still editing.

It exists for one situation in particular: **`deploy_version.sh` lives in a submodule**, so
editing this tooling makes the superproject dirty, and the script then refuses to run.

```sh
DEPLOY_VERSION_ALLOW_DIRTY=1 cmake --build BUILD --target deploy_versioned_myproject.elf
```

You do not need it just to *read* the counter — `deploy_version.sh next` and `list` never
check anything.

### `DEPLOY_VERSION_OVERRIDE` — emergency

For when you are on a plane, the network is down, or something external demands a specific
number.

```sh
DEPLOY_VERSION_OVERRIDE=1.42 cmake --build BUILD --target deploy_versioned_myproject.elf
```

It **never touches the network**, unconditionally — the same behaviour whether or not you
have connectivity, which is what you want in an emergency rather than "it depends what it
can reach".

Nothing records that `1.42` is in use, so **someone else can be allocated the same
number**. Close that gap as soon as you are online:
[reconcile it](#i-made-an-override-build-and-im-back-online), or at minimum push the
counter past it.

### Where to set them

```sh
# terminal
DEPLOY_VERSION_ALLOW_DIRTY=1 cmake --build BUILD --target deploy_versioned_myproject.elf
```

**CLion:** *Settings → Build, Execution, Deployment → CMake → (profile) → Environment*.

**`CMakeUserPresets.json`** (per-developer, gitignored):

```json
{
  "version": 6,
  "configurePresets": [
    {
      "name": "debug-dirty-ok",
      "inherits": "_common_config",
      "environment": {
        "DEPLOY_VERSION_ALLOW_DIRTY": "1"
      }
    }
  ]
}
```

---

## D. Runbook

### I want to deploy an image

```sh
cmake --build BUILD --config Debug --target deploy_versioned_myproject.elf
```

Requires a clean worktree, HEAD pushed, and submodules clean and pushed. On success the
image is in `images/Debug/` and a `deploy/*` tag points at your commit.

### What version will I get? What has been deployed?

```sh
./cmake/versioning/deploy_version.sh list
```

Read-only, no checks. From an IDE, build the **`deploy_version_list`** target.
To see just the next number: `deploy_version.sh next`.

### I want to compile the versioned image without deploying it

```sh
cmake --build BUILD --config Debug --target versioned_myproject.elf
```

Reads the counter, consumes nothing. Run it as often as you like.

### I need to set the next deploy version

```sh
./cmake/versioning/set_next_deploy_version.sh 1.200
```

From an IDE: set `DEPLOY_NEXT_VERSION=1.200` in the environment and build
**`deploy_version_set_next`**.

Only forward. A value at or below the current next is refused — see
[the counter cannot move backwards](#the-two-tag-namespaces).

### I need to bump the major version

Same command; remember the minor does not reset:

```sh
./cmake/versioning/deploy_version.sh next     # -> 1.00499
./cmake/versioning/set_next_deploy_version.sh 2.500
```

### "the working tree has uncommitted changes"

The deploy image must be reproducible from a commit. Commit or stash your changes.

If you are only testing the build, use
[`DEPLOY_VERSION_ALLOW_DIRTY=1`](#deploy_version_allow_dirty--development).

### "HEAD is not on any branch on origin"

Your commit is only on this machine. Either publish the branch, or merge it and publish
that — both satisfy the check, since it asks for *any* branch on origin, not this one:

```sh
git push                                        # publish this branch
git switch main && git merge - && git push      # or merge it first
```

Note what this is and is not protecting. Pushing the deploy tag *would* upload the commit —
a fresh clone can always `git checkout deploy/1.00129` and get the exact source, branch or
no branch. So reproducibility is not at stake. What is at stake is that the shipped code
would never reach a shared branch, leaving `main` not reflecting what is running in the
field, with nothing to flag the divergence.

### "submodule 'x' is not on any branch on origin"

**This one really is about recoverability**, unlike the case above. A superproject tag
records only a submodule's *commit ID*, never its objects — those live in a different
repository and are not carried along by the tag push. An unpushed submodule commit cannot
be recovered from the project at all.

```sh
cd <submodule> && git push && cd -
```

### "submodule 'x' is checked out at ..., which is not the commit recorded"

You moved a submodule but did not record it. Either keep the move:

```sh
git add <submodule> && git commit
```

or discard it:

```sh
git submodule update -- <submodule>
```

### "version 1.00130 was taken by someone else"

Someone deployed while you were building — the tag push was rejected, and **no image was
produced**. Nothing is broken.

Just run the deploy target again. It will pick up the next free number.

### I'm offline and need an image now

```sh
DEPLOY_VERSION_OVERRIDE=1.42 cmake --build BUILD --config Debug \
    --target deploy_versioned_myproject.elf
```

The image lands in `images/Debug/override/` and reports `VER=1.42-x`. Nothing records that
`1.42` is taken — reconcile when you are back online.

### I need the firmware string to be exactly 1.42, with no `-x`

When the version string has to match something external character for character, add
`DEPLOY_VERSION_NO_MARK=1`:

```sh
DEPLOY_VERSION_OVERRIDE=1.42 DEPLOY_VERSION_NO_MARK=1 cmake --build BUILD \
    --config Debug --target deploy_versioned_myproject.elf
```

The image still goes to `override/` and is still claimable — only the marker is dropped.
Understand what that costs: the binary becomes **indistinguishable from a proper deploy**,
so a device in the field can no longer tell you it bypassed the counter. The folder is then
the only remaining signal, and folders do not travel with a flashed image.

It is refused without `DEPLOY_VERSION_OVERRIDE`. A normal build needs no marker, and a
dirty build must keep its `-dirty` because it is not reproducible.

### I need a version that is BEHIND the current next

`set-next` will not do this — the counter only moves forward. But `DEPLOY_VERSION_OVERRIDE`
does not consult the counter at all, so it simply works:

```sh
DEPLOY_VERSION_OVERRIDE=1.75 cmake --build BUILD --config Debug \
    --target deploy_versioned_myproject.elf
```

What happens next depends on whether that number was ever used:

**If it was never used** — you are filling a gap below the high-water mark. `claim` will
publish `deploy/1.00075` normally, and **the counter does not move backwards**: the rule is
`max(minor of deploy/*) + 1`, so adding a lower tag leaves the maximum untouched. You end
up with a fully tracked, audited image at a low version, with no tags deleted and no
disruption to anyone else.

**If it was already shipped** — the build still succeeds, and that is a genuine hazard. You
get `GMAPP_00075_<crc>_<size>.bin` alongside the original `GMAPP_00075_...`: different
binaries whose names differ only in the checksum and size fields. Three things limit the
damage, none of them prevention:

- the image lands in `override/`, so it cannot overwrite the released one;
- the firmware reports `VER=1.75-x`, so a device says how it was built;
- `claim` refuses with "version was taken by someone else", so it can never be laundered
  into a proper deploy tag.

The hatch cannot warn you at build time — it makes no network call by design, so it has no
way to know the number is taken. Check first with `deploy_version.sh list` if you are
unsure.

> Do **not** try to achieve this by deleting tags. Deleting a `deploy/*` tag destroys the
> only record that a version shipped and frees the number for reissue, which is exactly
> what the counter exists to prevent. (For the record, the arithmetic is unintuitive: you
> would have to delete `deploy/*` tags **>= V**, `deploy-next/*` tags **> V**, and anything
> with a higher major regardless of its minor.)

### I made an override build and I'm back online

**Do this before you build anything else.** The state file is the only record of that
image's version and commit — no tag was pushed — and every build overwrites it. See
[if the state file is lost](#if-the-state-file-is-lost).

```sh
./cmake/versioning/deploy_version.sh claim --state BUILD/allocated_deploy_version.txt
```

From an IDE: build **`deploy_version_claim`**.

This publishes `deploy/<version>` retroactively, so the emergency image is accounted for
like any other. It refuses if:

- **the tree was dirty when you built it** — the image cannot honestly be attributed to a
  commit;
- **HEAD has moved since** — check out the original commit (it is recorded as `COMMIT=` in
  the state file) and try again.

If you cannot claim it, at least make sure the number is never reused:

```sh
./cmake/versioning/set_next_deploy_version.sh 1.43
```

### I'm iterating on deploy_version.sh itself

Test the script directly — no CMake needed:

```sh
./cmake/versioning/deploy_version.sh next
./cmake/versioning/deploy_version.sh list
```

For a full deploy-target run while the submodule is dirty, use
`DEPLOY_VERSION_ALLOW_DIRTY=1`.

### Which commit produced GMAPP_00129?

That is what the tags are for:

```sh
git show deploy/1.00129            # tagger, date, message, and the commit
git log -1 deploy/1.00129^{}
```

### Someone deleted a deploy tag

The number becomes free again and will be handed out a second time — two different
binaries with the same filename. Push the counter safely past the highest number ever
used:

```sh
./cmake/versioning/set_next_deploy_version.sh <higher-than-anything-shipped>
```

Then add the `deploy/**` deletion ruleset so it cannot happen again.

### I want to see every project at once

The project list lives **outside any repository**, because it names your private repos and
this one is public:

```sh
mkdir -p ~/.config/deploy-versions
cat >> ~/.config/deploy-versions/projects.txt <<'EOF'
git@github.com:your-org/project-one.git
git@github.com:your-org/project-two.git
EOF

./cmake/versioning/deploy_versions_overview.sh
```

Pass a path as an argument, or set `$DEPLOY_VERSIONS_PROJECTS`, to keep it somewhere else —
a private repo you control, for instance, so the team shares one list.

It deliberately cannot live next to the script. Besides this repository being public, that
directory is a *submodule* of your project, and a superproject records only a submodule's
commit ID, never its working-tree contents — so a file placed there could not be committed
anywhere at all.

```
PROJECT                              DEPLOYED         NEXT    COUNT
-------                              --------         ----    -----
myproject                             1.00129      1.00130        1
```

---

## Reference

### Commands

| Command | Network | Writes | Purpose |
|---|---|---|---|
| `deploy_version.sh next` | read | — | The version the next deploy will use |
| `deploy_version.sh list` | read | — | Everything the remote knows |
| `deploy_version.sh set-next <v>` | read+write | a tag | Choose the next version |
| `deploy_version.sh allocate --out F` | read | `F` | Called by the build |
| `deploy_version.sh commit --state F` | read+write | a tag | Called by the build; the allocation |
| `deploy_version.sh claim --state F` | read+write | a tag | Reconcile an override build |
| `set_next_deploy_version.sh <v>` | read+write | a tag | Forwarder for `set-next` |
| `deploy_versions_overview.sh` | read | — | Cross-project table |

All accept `--repo <dir>`. Without it, the script tags the superproject of wherever it
lives — correct when mounted as a submodule.

### Environment variables

| Variable | Effect |
|---|---|
| `DEPLOY_VERSION_ALLOW_DIRTY=1` | Skip repository checks. Marked `-dirty`, never tagged. |
| `DEPLOY_VERSION_OVERRIDE=<v>` | No network, no checks, exact version. Marked `-x`, never tagged. |
| `DEPLOY_VERSION_NO_MARK=1` | With `OVERRIDE` only: drop the `-x`, so the firmware string is exactly the version asked for. |
| `DEPLOY_VERSIONS_PROJECTS=<path>` | Project list for `deploy_versions_overview.sh`. Defaults to `~/.config/deploy-versions/projects.txt`. |
| `DEPLOY_NEXT_VERSION=<v>` | Version for the `deploy_version_set_next` target. |

### CMake targets

| Target | Equivalent |
|---|---|
| `deploy_versioned_<project>.elf` | build, tag, and publish an image |
| `versioned_<project>.elf` | build a versioned image without deploying |
| `deploy_version_list` | `deploy_version.sh list` |
| `deploy_version_set_next` | `deploy_version.sh set-next` (via `DEPLOY_NEXT_VERSION`) |
| `deploy_version_claim` | `deploy_version.sh claim --state …` |

The last three are thin forwarders, added for developers who work entirely in an IDE. The
scripts are the implementation and work standalone — which matters most when the build is
what is broken.

### A trap, if you modify this code

Annotated tags appear **twice** in `ls-remote` output:

```
42c4207…  refs/tags/deploy/1.00129        <- the TAG OBJECT
aa1516c…  refs/tags/deploy/1.00129^{}     <- the commit ("peeled")
```

and filtering by an exact ref does **not** return the peeled companion:

```console
$ git ls-remote --tags origin "refs/tags/deploy/1.00129"
42c4207…  refs/tags/deploy/1.00129        # only one line!
```

So a naive existence check compares a *tag* sha against a *commit* sha and never matches.
Both refs must be requested explicitly. This produced a false "version was taken by
someone else" on every idempotent re-deploy until it was found.
