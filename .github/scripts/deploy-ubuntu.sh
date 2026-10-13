
#!/usr/bin/env bash
set -Eeuo pipefail

# --------------------------------------------------
# 1. Validate release ID
# --------------------------------------------------
if [[ $# -ne 1 || ! "$1" =~ ^[0-9a-f]{40}$ ]]; then
    echo "ERROR: Pass a valid 40-character lowercase commit SHA."
    exit 1
fi

RELEASE_ID="$1"
BUCKET="dotnet-windows-s3"
ARTIFACT_KEY="artifacts/${RELEASE_ID}.zip"
WORK_DIR=""
ZIP_FILE=""
EXTRACT_DIR=""

echo "=== Ubuntu deployment preflight ==="
echo "Release: ${RELEASE_ID}"
echo "Artifact: s3://${BUCKET}/${ARTIFACT_KEY}"

# --------------------------------------------------
# 2. Verify required commands
# --------------------------------------------------
for cmd in aws python3 docker nginx curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $cmd"
        exit 1
    fi
done

# --------------------------------------------------
# 3. Verify services and current website
# --------------------------------------------------
if ! sudo systemctl is-active --quiet docker; then
    echo "ERROR: Docker service is not active."
    exit 1
fi

if ! sudo systemctl is-active --quiet nginx; then
    echo "ERROR: Host Nginx is not active."
    exit 1
fi

echo "=== Disk space ==="
df -h /

echo "=== Check current website ==="
HTTP_STATUS="$(curl --silent --show-error \
    --output /dev/null \
    --write-out '%{http_code}' \
    --max-time 10 \
    http://127.0.0.1/)"

if [[ "$HTTP_STATUS" != "200" ]]; then
    echo "ERROR: Current website returned HTTP ${HTTP_STATUS}."
    exit 1
fi

echo "Current website is healthy."

# --------------------------------------------------
# 4. Create an isolated temporary directory
# --------------------------------------------------
WORK_DIR="$(sudo mktemp -d /var/tmp/harley-deploy.XXXXXX)"
ZIP_FILE="${WORK_DIR}/website.zip"
EXTRACT_DIR="${WORK_DIR}/source"

cleanup() {
    if [[ -n "${WORK_DIR:-}" ]]; then
        sudo rm -rf -- "$WORK_DIR"
    fi
}

trap cleanup EXIT

sudo install -d -m 0750 "$EXTRACT_DIR"

echo "Temporary workspace created successfully."

# --------------------------------------------------
# 5. Download the exact release artifact
# --------------------------------------------------
echo "=== Download S3 artifact ==="
sudo aws s3 cp \
    "s3://${BUCKET}/${ARTIFACT_KEY}" \
    "$ZIP_FILE"

# --------------------------------------------------
# 6. Validate archive and file paths
# --------------------------------------------------
echo "=== Validate ZIP archive ==="

sudo python3 - "$ZIP_FILE" "$EXTRACT_DIR" <<'PY'
import pathlib
import stat
import sys
import zipfile

archive = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])

required = [
    "index.html",
    "index.css",
    "app.js",
    "harley-davidson-2.jpg",
]

with zipfile.ZipFile(archive) as z:
    bad_file = z.testzip()
    if bad_file:
        raise SystemExit(f"ERROR: Corrupt ZIP member: {bad_file}")

    names = z.namelist()
    seen = set()

    for info in z.infolist():
        name = info.filename
        path = pathlib.PurePosixPath(name)

        if (
            not name
            or path.is_absolute()
            or ".." in path.parts
            or "\\" in name
            or name.startswith("/")
            or (path.parts and ":" in path.parts[0])
        ):
            raise SystemExit(f"ERROR: Unsafe ZIP path: {name!r}")

        if name in seen:
            raise SystemExit(f"ERROR: Duplicate ZIP entry: {name!r}")
        seen.add(name)

        # Allow only regular files and directories in the archive.
        mode = info.external_attr >> 16
        file_type = stat.S_IFMT(mode)

        if file_type not in (0, stat.S_IFREG, stat.S_IFDIR):
            raise SystemExit(
                f"ERROR: Unsupported ZIP entry type: {name}"
            )

        if info.is_dir() and not name.endswith("/"):
            raise SystemExit(
                f"ERROR: Invalid directory entry: {name}"
            )

        if info.file_size > 100 * 1024 * 1024:
            raise SystemExit(f"ERROR: Oversized ZIP entry: {name}")

    if len(names) > 500:
        raise SystemExit("ERROR: Too many ZIP entries.")

    for filename in required:
        if filename not in seen:
            raise SystemExit(f"ERROR: Required file missing: {filename}")

    total_size = sum(info.file_size for info in z.infolist())
    if total_size > 200 * 1024 * 1024:
        raise SystemExit("ERROR: Uncompressed archive exceeds 200 MiB.")

    print(f"Archive integrity passed: {len(names)} entries.")
    print(f"Uncompressed size: {total_size} bytes.")
    print("Required website files are present.")

    # Verify every extraction target remains inside the staging directory.
    destination_resolved = destination.resolve()

    for info in z.infolist():
        target = (destination / info.filename).resolve()

        if target != destination_resolved and destination_resolved not in target.parents:
            raise SystemExit(
                f"ERROR: Extraction target escapes staging directory: {info.filename}"
            )

    # Extract only after all entries and destinations pass validation.
    z.extractall(destination)

print("Archive safely extracted to the temporary release directory.")
PY

echo "=== Confirm extracted website ==="
sudo test -s "${EXTRACT_DIR}/index.html"
sudo test -s "${EXTRACT_DIR}/index.css"
sudo test -s "${EXTRACT_DIR}/app.js"

echo "PASS: Artifact downloaded, validated and extracted."
echo "No Docker container or Nginx configuration was changed."
