#!/bin/bash
# The 50-motion benchmark (TACO 10, OakInk2 15, HOT3D 25 clips) -> <output_dataset_path>/<robot>/motion.pt:
# bash scripts/retarget/50_motion_benchmark.sh <taco_raw> <oakink2_raw> <hot3d_raw> <output_dataset_path> [overrides]
set -e
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPTS/../.." && pwd)"
if [ $# -lt 4 ]; then
    cat >&2 <<USAGE
Usage: bash scripts/retarget/50_motion_benchmark.sh <taco_raw> <oakink2_raw> <hot3d_raw> <output_dataset_path> [Hydra overrides of kinematic_retargeting.yaml]
  <*_raw>                the three releases, laid out as taco.sh, oakink2.sh and hot3d_1obj.sh read them
  <output_dataset_path>  human_demo/ (the 50 clips) and objects/ (shared), <robot>/{retargeted/, report.csv, motion.pt}
  ROBOTS                 robots to retarget to, one after another (default: "xhand sharpa")
  REIMPORT               1: import again although <output_dataset_path>/human_demo/ has every clip
  e.g. bash scripts/retarget/50_motion_benchmark.sh /data/taco /data/oakink2 /data/hot3d /data/benchmark_50 workers=64
USAGE
    exit 1
fi
[ -f "$REPO_DIR/scripts/env.sh" ] && source "$REPO_DIR/scripts/env.sh"
declare -A RAW=([taco]=$1 [oakink2]=$2 [hot3d]=$3)
OUT=$4
shift 4
WORKERS=$(printf '%s\n' "$@" | grep -m1 '^workers=' || true)   # also used by the import

# <source> <clip> <frames>, as the importer names the clips; HOT3D segment numbers follow the importer's
# segmentation, so the frame counts catch a name that points at another segment
BENCHMARK="
taco taco_brush__eraser__bowl_20231103_035 199
taco taco_cut__spoon__bowl_20231027_084 283
taco taco_empty__box__plate_20231027_159 397
taco taco_pour_in_some__bowl__cup_20231006_261 297
taco taco_put_in__spoon__bowl_20231005_127 217
taco taco_put_out__spoon__pan_20231005_107 259
taco taco_scrape_off__spatula__pan_20231005_018 257
taco taco_scrape_off__spoon__plate_20231024_097 401
taco taco_stir-fry__spoon__pan_20230923_019 623
taco taco_stir__spoon__pan_20231006_056 237
oakink2 scene_01__A003++seq__1eccd6dfd6b93888e9d1__2023-04-23-20-27-53__st05 1417
oakink2 scene_01__A003++seq__3ae08d6cbcd1458a57fc__2023-04-15-11-18-20__st01 1215
oakink2 scene_01__A003++seq__5a5d66e7a358b59c9fee__2023-04-21-20-23-45__st08 1781
oakink2 scene_01__A003++seq__ce2f09a1ccbe225a69aa__2023-04-23-19-08-48__st01 1277
oakink2 scene_01__A004++seq__4102ced88c60ebdf8023__2023-04-28-18-37-52__st00 1001
oakink2 scene_01__A004++seq__c1e3698b2dfc3650fa61__2023-04-28-18-35-15__st00 947
oakink2 scene_01__A005++seq__d01e231560b7068d4149__2023-04-15-14-24-56__st00 685
oakink2 scene_01__A005++seq__fccd810e2fd673b25c86__2023-04-15-14-30-47__st00 559
oakink2 scene_01__A007++seq__3783890ba75da6556f48__2023-04-21-10-24-03__st00 330
oakink2 scene_01__O001++seq__1292e65ea2c7e60dade4__2023-04-13-19-00-36__st00 793
oakink2 scene_02__A007++seq__06d2f1c8ee39209ea62a__2023-05-15-19-37-06__st09 568
oakink2 scene_03__A004++seq__0f90057f6302c9e0a117__2023-04-26-19-33-13__st10 364
oakink2 scene_03__A004++seq__419a3a06276de7db2371__2023-04-22-20-25-48__st01 757
oakink2 scene_03__A007++seq__b4d4456ced6f3803440c__2023-04-19-11-32-19__st04 743
oakink2 scene_04__A007++seq__a4cf2a5ebe1053befdce__2023-04-19-10-35-51__st00 415
hot3d P0001_8d136980_seg016 251
hot3d P0001_95eabc0a_seg009 329
hot3d P0001_9b6feab7_seg017 345
hot3d P0001_a9d6c83d_seg017 347
hot3d P0001_b2bcbe28_seg015 485
hot3d P0002_1464cbdc_seg004 263
hot3d P0002_c3aec89e_seg013 445
hot3d P0003_3c64374c_seg020 217
hot3d P0003_414fb0e3_seg004 445
hot3d P0003_613ab44f_seg008 337
hot3d P0003_b0a97c8d_seg004 519
hot3d P0003_ebdc6ff7_seg001 865
hot3d P0003_ebdc6ff7_seg012 323
hot3d P0009_24af5475_seg012 181
hot3d P0010_086ff32a_seg002 571
hot3d P0010_1c9fe708_seg001 485
hot3d P0010_924e574e_seg002 545
hot3d P0011_cd22f5e0_seg006 473
hot3d P0013_a2b36677_seg007 413
hot3d P0018_15ad9743_seg009 315
hot3d P0018_3271b3c2_seg004 427
hot3d P0018_3271b3c2_seg016 209
hot3d P0018_3da09d68_seg011 361
hot3d P0018_a74d82ff_seg010 375
hot3d P0021_1bad784d_seg006 839
"
clips() { awk -v s="$1" 'NF && (s == "" || $1 == s) {print $2}' <<< "$BENCHMARK"; }

release_files() {  # <source> <clip>: the release files the clip is imported from, then the shared meshes
    case $1 in
        taco)  # taco_put_in__spoon__bowl_20231005_127 <- (put in, spoon, bowl)/20231005_127
            local t=${2#taco_}
            local triplet=${t%_*_*} seq=${t: -12}
            triplet=${triplet//__/, }
            printf '%s\n' "Hand_Poses/(${triplet//_/ })/$seq" "Object_Poses/(${triplet//_/ })/$seq" object_models_released ;;
        oakink2) printf '%s\n' "anno_preview/${2%__st*}.pkl" "program/program_info/${2%__st*}.json" object_repair ;;
        hot3d) printf '%s\n' "dataset/${2%_seg*}" _assets ;;
    esac
}

used_objects() {  # <human_demo>: the object ids its clips hold or fit the desk on
    python - "$1" <<'PY'
import sys
from pathlib import Path

import numpy as np

ids = set()
for p in Path(sys.argv[1]).glob("*.npz"):
    with np.load(p, allow_pickle=True) as z:
        for k in ("obj_right_id", "obj_left_id", "desk_context_ids"):
            if k in z.files:
                ids.update(map(str, np.atleast_1d(z[k])))
print("\n".join(sorted(ids)))
PY
}

missing=0
for clip in $(clips); do [ -f "$OUT/human_demo/$clip.npz" ] || missing=$((missing + 1)); done
if [ $missing = 0 ] && [ "${REIMPORT:-0}" != 1 ]; then
    echo "[retarget/50_motion_benchmark] $OUT/human_demo has every clip: import skipped (REIMPORT=1 to redo)"
else
    # Each release is cut down to the benchmark's recordings (symlinks) and imported; only the 50 clips are kept,
    # with the meshes they use (their objects, OakInk2's desk context), not every object of their recordings.
    STAGE=$OUT/.import
    rm -rf "$STAGE"
    mkdir -p "$OUT/human_demo" "$OUT/objects"
    for src in taco oakink2 hot3d; do
        raw=$(cd "${RAW[$src]}" && pwd)
        for clip in $(clips $src); do
            while IFS= read -r f; do
                [ -e "$raw/$f" ] || { echo "[retarget/50_motion_benchmark] $clip: $raw/$f not found" >&2; exit 1; }
                mkdir -p "$(dirname "$STAGE/$src/raw/$f")"
                ln -sfn "$raw/$f" "$STAGE/$src/raw/$f"
            done < <(release_files $src "$clip")
        done
        # P0010_1c9fe708_seg001 has a one-frame 87 deg object-tracking jump; the benchmark keeps it.
        [ $src = hot3d ] && extra=max_obj_rot_step_deg=181 || extra=
        bash "$SCRIPTS/import_human_demo.sh" source=$src raw="$STAGE/$src/raw" dataset="$STAGE/$src" $WORKERS $extra
        for clip in $(clips $src); do
            [ -f "$STAGE/$src/human_demo/$clip.npz" ] || { echo "[retarget/50_motion_benchmark] $clip was not imported" >&2; exit 1; }
            mv "$STAGE/$src/human_demo/$clip.npz" "$OUT/human_demo/"
        done
    done
    ids=$(used_objects "$OUT/human_demo")
    for id in $ids; do
        [ -e "$OUT/objects/$id" ] || mv "$STAGE"/*/objects/"$id" "$OUT/objects/"
    done
    rm -rf "$STAGE"
fi

python - "$OUT/human_demo" "$BENCHMARK" <<'PY'
import sys
from pathlib import Path

import numpy as np

demo, bad = Path(sys.argv[1]), []
for src, clip, frames in (line.split() for line in sys.argv[2].splitlines() if line.strip()):
    with np.load(demo / f"{clip}.npz") as z:
        n = len(z["mano_right_wrist_pos"])
    if n != int(frames):
        bad.append(f"{clip} has {n} frames, not {frames}")
if bad:
    sys.exit("[retarget/50_motion_benchmark] not the benchmark's clips: " + "; ".join(bad))
PY

# wrist_acc_spike would reject three benchmark clips (66, 76 and 186 m/s^2).
for robot in ${ROBOTS:-xhand sharpa}; do
    mkdir -p "$OUT/$robot"
    ln -sfn ../human_demo "$OUT/$robot/human_demo"
    ln -sfn ../objects "$OUT/$robot/objects"
    bash "$SCRIPTS/kinematic_retargeting.sh" dataset="$OUT/$robot" robot="$robot" filters.wrist_acc_spike.max_acc=200 "$@"
done

for robot in ${ROBOTS:-xhand sharpa}; do
    [ -f "$OUT/$robot/motion.pt" ] || continue
    python - "$OUT/$robot/motion.pt" $(clips) <<'PY'
import sys

import torch

path, names = sys.argv[1], sys.argv[2:]
missing = sorted(set(names) - set(torch.load(path, map_location="cpu", weights_only=False)["motion_filename"]))
print(f"[retarget/50_motion_benchmark] {path}: {len(names) - len(missing)}/{len(names)} clips"
      + (f", missing {missing} (see report.csv)" if missing else ""))
sys.exit(1 if missing else 0)
PY
done
