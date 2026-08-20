#!/usr/bin/env python3
"""Build the WHOLE-BRAIN binary network file from FlyWire Codex v783 dumps.

Unlike etl.py (which selects a 668-neuron circuit and writes JSON), this keeps
every classified neuron and every connection, and writes a flat binary CSR that
Sim.swift can read straight into [UInt32]/[Float] with no parsing.

Inputs (same raw Codex downloads as etl.py):
  classification.csv.gz          root_id, flow, super_class, class, ..., side, nerve
  coordinates.csv.gz             root_id, position "[x y z]" (nm), supervoxel_id
  connections.csv.gz             pre_root_id, post_root_id, neuropil, syn_count, nt_type
  consolidated_cell_types.csv.gz root_id, primary_type, additional_type(s)

Output:
  data/fullbrain.bin   ~24 MB, little-endian, layout documented in HEADER below

Usage: python3 etl_fullbrain.py <raw_dir>

Data is FlyWire (CC BY-NC 4.0) — see data/DATA_LICENSE.md.
"""
import csv, gzip, os, struct, sys
from collections import defaultdict

RAW = sys.argv[1] if len(sys.argv) > 1 else "."
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
os.makedirs(OUT, exist_ok=True)

MAGIC = b"FLYB"
VERSION = 1

# role ids MUST match the Role enum in Sim.swift
ROLES = ["other", "lc4", "lplc2", "gf", "dna01", "dna02", "dnp09", "dng11",
         "mdn", "escw", "ascending", "sensory", "food_orn"]
ROLE_ID = {r: i for i, r in enumerate(ROLES)}

CORE_TYPES = {          # primary_type -> role (same set etl.py uses)
    "LC4": "lc4", "LPLC2": "lplc2", "DNp01": "gf",
    "DNa02": "dna02", "DNa01": "dna01", "DNp09": "dnp09",
    "DNg11": "dng11", "MDN": "mdn",
    "DNp02": "escw", "DNp04": "escw", "DNp11": "escw",
    # food-odor ORNs: antennal-lobe glomeruli documented as attraction-driving
    # (DM1/Or42b, DM4/Or59b, VA2/Or92a, VM3, DP1m -- see Nat. Commun. 2019,
    # 10.1038/s41467-019-09069-1). Without this they'd fall into the generic
    # "sensory" bucket (tap/wind -> GF) undifferentiated from everything else.
    "ORN_DM1": "food_orn", "ORN_DM4": "food_orn", "ORN_VA2": "food_orn",
    "ORN_VM3": "food_orn", "ORN_DP1m": "food_orn",
}
# super_class -> role, applied only where no CORE_TYPES match (input pathways)
SUPER_ROLE = {"ascending": "ascending", "sensory_ascending": "ascending",
              "sensory": "sensory"}

SUPER_CLASSES = ["optic", "central", "sensory", "visual_projection",
                 "visual_centrifugal", "descending", "ascending", "motor",
                 "endocrine", "sensory_ascending"]
SC_ID = {s: i for i, s in enumerate(SUPER_CLASSES)}
SIDE_ID = {"center": 0, "left": 1, "right": 2}

NT_SIGN = {"ACH": 1.0, "GABA": -1.0, "GLUT": -1.0, "DA": 0.5, "SER": 0.5, "OCT": 0.5}


def rows(name):
    with gzip.open(os.path.join(RAW, name), "rt") as f:
        r = csv.reader(f)
        next(r)
        yield from r


# --- neurons ---------------------------------------------------------------
klass = {}
for row in rows("classification.csv.gz"):
    klass[row[0]] = (row[2], row[6])          # super_class, side
print(f"classified neurons: {len(klass):,}")

core_role = {}
for row in rows("consolidated_cell_types.csv.gz"):
    r = CORE_TYPES.get(row[1].strip())
    if r:
        core_role[row[0]] = r
print(f"core-population neurons: {len(core_role):,}")

pos = {}
for row in rows("coordinates.csv.gz"):
    rid = row[0]
    if rid in pos:
        continue
    p = row[1].strip("[]").split()
    if len(p) == 3:
        pos[rid] = (float(p[0]), float(p[1]), float(p[2]))
print(f"coordinates: {len(pos):,}")

ids = sorted(klass)
idx = {rid: i for i, rid in enumerate(ids)}
n = len(ids)

# normalization: fit the whole brain into [-10, 10], same transform as etl.py
xs = [p[0] for p in pos.values()]
ys = [p[1] for p in pos.values()]
zs = [p[2] for p in pos.values()]
cx, cy, cz = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2, (min(zs) + max(zs)) / 2
scale = 20.0 / max(max(xs) - min(xs), max(ys) - min(ys), max(zs) - min(zs))


def norm(p):
    # FAFB: x left-right, y dorsal-ventral (image y down), z anterior-posterior
    return ((p[0] - cx) * scale, -(p[1] - cy) * scale, -(p[2] - cz) * scale)


# --- edges: aggregate per unique (pre, post) across neuropils ---------------
# connections.csv has one row per (pre, post, neuropil); summing keeps one CSR
# entry per synaptic partner pair instead of 3.87M duplicated rows.
agg = defaultdict(float)
nt_missing = 0
for row in rows("connections.csv.gz"):
    i, j = idx.get(row[0]), idx.get(row[1])
    if i is None or j is None:
        continue
    sign = NT_SIGN.get(row[4].strip().upper())
    if sign is None:
        sign, nt_missing = 1.0, nt_missing + 1
    agg[(i, j)] += int(row[3]) * sign
print(f"unique edges: {len(agg):,} (unknown nt on {nt_missing:,} rows)")

# --- CSR --------------------------------------------------------------------
counts = [0] * n
for (i, _j) in agg:
    counts[i] += 1
row_start = [0] * (n + 1)
for i in range(n):
    row_start[i + 1] = row_start[i] + counts[i]
n_edges = row_start[n]

col = [0] * n_edges
wgt = [0.0] * n_edges
fill = row_start[:]
for (i, j), w in agg.items():
    k = fill[i]
    col[k] = j
    wgt[k] = w
    fill[i] = k + 1

# --- write ------------------------------------------------------------------
path = os.path.join(OUT, "fullbrain.bin")
with open(path, "wb") as f:
    f.write(MAGIC)
    f.write(struct.pack("<III", VERSION, n, n_edges))
    # neuron table: role u8, side u8, super u8, pad u8, x/y/z f32  (16 B each)
    role_hist = defaultdict(int)
    buf = bytearray()
    for rid in ids:
        sc, side = klass[rid]
        role = core_role.get(rid) or SUPER_ROLE.get(sc) or "other"
        role_hist[role] += 1
        x, y, z = norm(pos[rid]) if rid in pos else (0.0, 0.0, 0.0)
        buf += struct.pack("<BBBBfff", ROLE_ID[role], SIDE_ID.get(side, 0),
                           SC_ID.get(sc, 1), 0, x, y, z)
    f.write(buf)
    f.write(struct.pack(f"<{n + 1}I", *row_start))
    f.write(struct.pack(f"<{n_edges}I", *col))
    f.write(struct.pack(f"<{n_edges}f", *wgt))

size = os.path.getsize(path)
print(f"\nfullbrain.bin: {n:,} neurons, {n_edges:,} edges, {size / 1e6:.1f} MB")
print("roles:", dict(sorted(role_hist.items(), key=lambda kv: -kv[1])))

# --- report -----------------------------------------------------------------
exc = sum(1 for w in wgt if w > 0)
print(f"excitatory edges: {exc / n_edges * 100:.1f}%  inhibitory: {(1 - exc / n_edges) * 100:.1f}%")
tot_syn = sum(abs(w) for w in wgt)
print(f"total synapses: {tot_syn:,.0f}, mean |w| per edge: {tot_syn / n_edges:.2f}")
print(f"mean out-degree: {n_edges / n:.1f}")

role_of = {}
for i, rid in enumerate(ids):
    role_of[i] = core_role.get(rid) or SUPER_ROLE.get(klass[rid][0]) or "other"
indeg = defaultdict(float)
for (i, j), w in agg.items():
    indeg[role_of[j]] += abs(w)
for r in ("gf", "dna01", "dna02", "dnp09", "dng11", "mdn", "escw"):
    print(f"  in-brain drive onto {r}: {indeg[r]:,.0f} syn")

# food_orn is a sensory INPUT population (like lc4/lplc2/sensory), so the
# relevant check is the opposite direction: does injected excitation actually
# go anywhere, or is it a dead end?
outdeg = defaultdict(float)
for (i, j), w in agg.items():
    outdeg[role_of[i]] += abs(w)
print(f"  food_orn outgoing drive onto the rest of the brain: {outdeg['food_orn']:,.0f} syn"
      f" ({role_hist.get('food_orn', 0)} neurons)")
