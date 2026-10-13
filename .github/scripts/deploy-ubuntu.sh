```bash
#!/usr/bin/env bash
set -Eeuo pipefail

# Release-specific Docker candidate deployment
if [[ $# -ne 1 || ! "$1" =~ ^[0-9a-f]{40}$ ]]; then
    echo "ERROR: Provide a valid 40-character lowercase commit SHA."
    exit 1
fi

RELEASE_ID="$1"
BUCKET="dotnet-windows-s3"
ARTIFACT_KEY="artifacts/${RELEASE_ID}.zip"
IMAGE="harley-davidson:${RELEASE_ID}"
CANDIDATE="harley-davidson-candidate-${RELEASE_ID:0:12}"
PORT="127.0.0.1:8081"
WORK_DIR="$(sudo mktemp -d /var/tmp/harley-deploy.XXXXXX)"

cleanup() {
    sudo rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT

for cmd in aws python3 docker curl; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "ERROR: Missing command: $cmd"
        exit 1
    }
done

sudo systemctl is-active --quiet docker
sudo systemctl is-active --quiet nginx
curl -fsS --max-time 10 http://127.0.0.1/ >/dev/null

ZIP_FILE="${WORK_DIR}/website.zip"
SOURCE_DIR="${WORK_DIR}/source"
sudo install -d -m 0750 "$SOURCE_DIR"

echo "Downloading release ${RELEASE_ID}"
sudo aws s3 cp "s3://${BUCKET}/${ARTIFACT_KEY}" "$ZIP_FILE"

echo "Validating and extracting archive"
sudo python3 - "$ZIP_FILE" "$SOURCE_DIR" <<'PY'
import pathlib, stat, sys, zipfile

archive = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
required = [
    "index.html", "index.css", "app.js",
    "Icon_Harley-Davidson.jpeg", "harley-davidson-2.jpg"
]

with zipfile.ZipFile(archive) as z:
    if z.testzip():
        raise SystemExit("ERROR: Corrupt ZIP archive")
    entries = z.infolist()
    seen = set()

    if len(entries) > 500:
        raise SystemExit("ERROR: Too many archive entries")

    total = 0
    for item in entries:
        name = item.filename
        path = pathlib.PurePosixPath(name)
        mode = item.external_attr >> 16
        kind = stat.S_IFMT(mode)

        if (not name or path.is_absolute() or ".." in path.parts
                or "\\" in name or (path.parts and ":" in path.parts[0])):
            raise SystemExit(f"ERROR: Unsafe archive path: {name!r}")
        if name in seen:
            raise SystemExit(f"ERROR: Duplicate archive entry: {name!r}")
        seen.add(name)

        if kind not in (0, stat.S_IFREG, stat.S_IFDIR):
            raise SystemExit(f"ERROR: Unsupported entry type: {name}")
        if item.file_size > 100 * 1024 * 1024:
            raise SystemExit(f"ERROR: Oversized entry: {name}")

        total += item.file_size

    if total > 200 * 1024 * 1024:
        raise SystemExit("ERROR: Archive exceeds 200 MiB uncompressed")

    for name in required:
        if name not in seen:
            raise SystemExit(f"ERROR: Required file missing: {name}")

    root = destination.resolve()
    for item in entries:
        target = (destination / item.filename).resolve()
        if target != root and root not in target.parents:
            raise SystemExit(f"ERROR: Unsafe extraction target: {item.filename}")

    z.extractall(destination)

for name in required:
    if not (destination / name).is_file() or (destination / name).stat().st_size == 0:
        raise SystemExit(f"ERROR: Missing or empty file: {name}")

print("Archive validation passed")
PY

echo "Checking available disk space"
AVAILABLE_KB="$(df -Pk / | awk 'NR==2 {print $4}')"
if [[ "$AVAILABLE_KB" -lt 1048576 ]]; then
    echo "ERROR: Less than 1 GiB disk space available"
    exit 1
fi

echo "Building release image: ${IMAGE}"
sudo docker build --pull -t "$IMAGE" "$SOURCE_DIR"

echo "Starting isolated candidate on port 8081"
if sudo docker container inspect "$CANDIDATE" >/dev/null 2>&1; then
    echo "ERROR: Candidate name already exists: $CANDIDATE"
    echo "Inspect it before removing or reusing it."
    exit 1
fi

sudo docker run -d \
    --name "$CANDIDATE" \
    --restart=no \
    --publish "${PORT}:80" \
    "$IMAGE"

echo "Testing candidate HTTP response"
for attempt in $(seq 1 15); do
    if curl -fsS --max-time 3 http://127.0.0.1:8081/ \
        -o "${WORK_DIR}/candidate.html"; then
        break
    fi
    if [[ "$attempt" -eq 15 ]]; then
        echo "ERROR: Candidate did not become healthy"
        sudo docker logs "$CANDIDATE" || true
        exit 1
    fi
    sleep 2
done

grep -qi '<html' "${WORK_DIR}/candidate.html" || {
    echo "ERROR: Candidate did not return expected HTML"
    exit 1
}

for file in index.css app.js Icon_Harley-Davidson.jpeg harley-davidson-2.jpg; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' \
        --max-time 5 "http://127.0.0.1:8081/${file}")"
    [[ "$code" == "200" ]] || {
        echo "ERROR: Candidate asset ${file} returned HTTP ${code}"
        exit 1
    }
done

echo "SUCCESS: Candidate passed HTTP and asset checks."
echo "Release: ${RELEASE_ID}"
echo "Image: ${IMAGE}"
echo "Candidate: ${CANDIDATE}"
echo "Live Nginx upstream remains unchanged at 127.0.0.1:8080."
echo "Promotion is intentionally not performed by this script."
```