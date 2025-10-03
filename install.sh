#!/bin/bash

# --- Definitive High-Speed Installation Script ---
# This script uses 'uv' for fast Python package installation and 'aria2c' for
# multi-threaded, concurrent downloads to achieve the fastest possible setup time.

# cd into GPT-SoVITS Base Path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

cd "$SCRIPT_DIR" || exit 1

# --- Terminal Colors for Better Readability ---
RESET="\033[0m"
BOLD="\033[1m"
ERROR="\033[1;31m[ERROR]: $RESET"
WARNING="\033[1;33m[WARNING]: $RESET"
INFO="\033[1;32m[INFO]: $RESET"
SUCCESS="\033[1;34m[SUCCESS]: $RESET"

set -eE
set -o errtrace

trap 'on_error $LINENO "$BASH_COMMAND" $?' ERR

# --- Error Handling Function ---
on_error() {
    local lineno="$1"
    local cmd="$2"
    local code="$3"

    echo -e "${ERROR}${BOLD}Command \"${cmd}\" Failed${RESET} at ${BOLD}Line ${lineno}${RESET} with Exit Code ${BOLD}${code}${RESET}"
    echo -e "${ERROR}${BOLD}Call Stack:${RESET}"
    for ((i = ${#FUNCNAME[@]} - 1; i >= 1; i--)); do
        echo -e "  in ${BOLD}${FUNCNAME[i]}()${RESET} at ${BASH_SOURCE[i]}:${BOLD}${BASH_LINENO[i - 1]}${RESET}"
    done
    exit "$code"
}

# --- Wrapper Functions for Package Managers ---
run_conda_quiet() {
    local output
    output=$(conda install --yes --quiet -c conda-forge "$@" 2>&1) || {
        echo -e "${ERROR} Conda install failed:\n$output"
        exit 1
    }
}

run_pip_quiet() {
    local output
    output=$(uv pip install "$@" 2>&1) || {
        echo -e "${ERROR} UV Pip install failed:\n$output"
        exit 1
    }
}

# --- OPTIMIZATION: High-speed download function using aria2c ---
run_aria2c() {
    # Using 16 connections per download for maximum speed.
    # The command takes a list of URLs as arguments.
    aria2c --console-log-level=warn -c -x 16 -s 16 -k 1M --max-tries=5 --retry-wait=5 "$@" || {
        echo -e "${ERROR} aria2c download failed."
        exit 1
    }
}

if ! command -v conda &>/dev/null; then
    echo -e "${ERROR}Conda Not Found"
    exit 1
fi

# --- Script Configuration ---
USE_CUDA=false
USE_ROCM=false
USE_CPU=false
WORKFLOW=${WORKFLOW:-"false"}
USE_HF=false
USE_HF_MIRROR=false
USE_MODELSCOPE=false
DOWNLOAD_UVR5=false

print_help() {
    echo "Usage: bash install.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --device   CU126|CU128|ROCM|MPS|CPU    Specify the Device (REQUIRED)"
    echo "  --source   HF|HF-Mirror|ModelScope     Specify the model source (REQUIRED)"
    echo "  --download-uvr5                        Enable downloading the UVR5 model"
    echo "  -h, --help                             Show this help message and exit"
    echo ""
    echo "Examples:"
    echo "  bash install.sh --device CU128 --source HF --download-uvr5"
    echo "  bash install.sh --device MPS --source ModelScope"
}

# Argument Parsing (no changes from original)
if [[ $# -eq 0 ]]; then print_help; exit 0; fi
while [[ $# -gt 0 ]]; do
    case "$1" in
    --source)
        case "$2" in HF) USE_HF=true;; HF-Mirror) USE_HF_MIRROR=true;; ModelScope) USE_MODELSCOPE=true;; *) echo -e "${ERROR}Invalid Source: $2"; exit 1;; esac; shift 2;;
    --device)
        case "$2" in CU126) CUDA=126; USE_CUDA=true;; CU128) CUDA=128; USE_CUDA=true;; ROCM) USE_ROCM=true;; MPS|CPU) USE_CPU=true;; *) echo -e "${ERROR}Invalid Device: $2"; exit 1;; esac; shift 2;;
    --download-uvr5) DOWNLOAD_UVR5=true; shift;;
    -h|--help) print_help; exit 0;;
    *) echo -e "${ERROR}Unknown Argument: $1"; print_help; exit 1;;
    esac
done

# Validation (no changes from original)
if ! $USE_CUDA && ! $USE_ROCM && ! $USE_CPU; then echo -e "${ERROR}Device is REQUIRED"; print_help; exit 1; fi
if ! $USE_HF && ! $USE_HF_MIRROR && ! $USE_MODELSCOPE; then echo -e "${ERROR}Download Source is REQUIRED"; print_help; exit 1; fi

case "$(uname -m)" in
x86_64|amd64) SYSROOT_PKG="sysroot_linux-64>=2.28";;
aarch64|arm64) SYSROOT_PKG="sysroot_linux-aarch64>=2.28";;
ppc64le) SYSROOT_PKG="sysroot_linux-ppc64le>=2.28";;
*) echo "Unsupported architecture: $(uname -m)"; exit 1;;
esac

# --- PHASE 1: System-level Dependencies ---
echo -e "${INFO}Detected system: $(uname -s) $(uname -r) $(uname -m)"
if [ "$(uname)" != "Darwin" ]; then
    gcc_major_version=$(command -v gcc >/dev/null 2>&1 && gcc -dumpversion | cut -d. -f1 || echo 0)
    if [ "$gcc_major_version" -lt 11 ]; then
        echo -e "${INFO}Installing GCC, G++, and essential tools (uv, aria2, etc)..."
        run_conda_quiet gcc=11 gxx=11 "$SYSROOT_PKG" ffmpeg cmake make unzip uv aria2
    else
        echo -e "${INFO}Detected GCC Version: $gcc_major_version. Installing tools (uv, aria2, etc)..."
        run_conda_quiet "libstdcxx-ng>=$gcc_major_version" ffmpeg cmake make unzip uv aria2
    fi
else
    # macOS specific logic
    if ! xcode-select -p &>/dev/null; then
        echo -e "${INFO}Installing Xcode Command Line Tools..."
        xcode-select --install
        echo -e "${INFO}Waiting For Xcode Command Line Tools Installation Complete..."
        while ! xcode-select -p &>/dev/null; do sleep 20; echo -e "${INFO}Still waiting..."; done
    fi
    echo -e "${INFO}Installing essential tools (uv, aria2, etc)..."
    run_conda_quiet ffmpeg cmake make unzip uv aria2
fi
echo -e "${SUCCESS}System-level dependencies and tools are ready."

# --- PHASE 2: High-Speed Parallel Download ---
if [ "$USE_HF" = "true" ]; then
    echo -e "${INFO}Download Source: HuggingFace"
    BASE_URL="https://huggingface.co/XXXXRT/GPT-SoVITS-Pretrained/resolve/main"
elif [ "$USE_HF_MIRROR" = "true" ]; then
    echo -e "${INFO}Download Source: HuggingFace-Mirror"
    BASE_URL="https://hf-mirror.com/XXXXRT/GPT-SoVITS-Pretrained/resolve/main"
elif [ "$USE_MODELSCOPE" = "true" ]; then
    echo -e "${INFO}Download Source: ModelScope"
    BASE_URL="https://www.modelscope.cn/models/XXXXRT/GPT-SoVITS-Pretrained/resolve/master"
fi

DOWNLOAD_LIST=()

# Build the list of files to download
if [ ! -d "GPT_SoVITS/pretrained_models/sv" ]; then
    DOWNLOAD_LIST+=("--out=pretrained_models.zip" "$BASE_URL/pretrained_models.zip")
fi
if [ ! -d "GPT_SoVITS/text/G2PWModel" ]; then
    DOWNLOAD_LIST+=("--out=G2PWModel.zip" "$BASE_URL/G2PWModel.zip")
fi
if [ "$DOWNLOAD_UVR5" = "true" ] && ! find -L "tools/uvr5/uvr5_weights" -mindepth 1 ! -name '.gitignore' | grep -q .; then
    DOWNLOAD_LIST+=("--out=uvr5_weights.zip" "$BASE_URL/uvr5_weights.zip")
fi
DOWNLOAD_LIST+=("--out=nltk_data.zip" "$BASE_URL/nltk_data.zip")
DOWNLOAD_LIST+=("--out=open_jtalk_dic_utf_8-1.11.tar.gz" "$BASE_URL/open_jtalk_dic_utf_8-1.11.tar.gz")

if [ ${#DOWNLOAD_LIST[@]} -gt 0 ]; then
    echo -e "${INFO}Starting high-speed download with aria2c..."
    run_aria2c "${DOWNLOAD_LIST[@]}"
    echo -e "${SUCCESS}All files downloaded."
else
    echo -e "${INFO}All models and data files already exist. Skipping download."
fi

# --- PHASE 3: Unpacking ---
echo -e "${INFO}Unpacking files..."
if [ -f "pretrained_models.zip" ]; then
    unzip -q -o pretrained_models.zip -d GPT_SoVITS && rm pretrained_models.zip
fi
if [ -f "G2PWModel.zip" ]; then
    unzip -q -o G2PWModel.zip -d GPT_SoVITS/text && rm G2PWModel.zip
fi
if [ -f "uvr5_weights.zip" ]; then
    unzip -q -o uvr5_weights.zip -d tools/uvr5 && rm uvr5_weights.zip
fi
if [ -f "nltk_data.zip" ]; then
    PY_PREFIX=$(python -c "import sys; print(sys.prefix)")
    unzip -q -o nltk_data.zip -d "$PY_PREFIX" && rm nltk_data.zip
fi
echo -e "${SUCCESS}Unpacking complete."

# --- PHASE 4: Python Environment Setup ---
if [ "$USE_CUDA" = true ] && [ "$WORKFLOW" = false ]; then
    if ! command -v nvidia-smi &>/dev/null; then
        echo -e "${WARNING}Nvidia Driver Not Found, Fallback to CPU"
        USE_CUDA=false; USE_CPU=true
    fi
fi
if [ "$USE_ROCM" = true ] && [ "$WORKFLOW" = false ]; then
    if [ ! -d "/opt/rocm" ]; then
        echo -e "${WARNING}ROCm Not Found, Fallback to CPU"
        USE_ROCM=false; USE_CPU=true
    else
        IS_WSL=$(grep -qi "microsoft" /proc/version && echo "true" || echo "false")
    fi
fi

if [ "$WORKFLOW" = false ]; then
    if [ "$USE_CUDA" = true ]; then
        PYTORCH_INDEX_URL="https://download.pytorch.org/whl/cu${CUDA}"
    elif [ "$USE_ROCM" = true ]; then
        PYTORCH_INDEX_URL="https://download.pytorch.org/whl/rocm6.2" # Adjust version if needed
    else # CPU or MPS
        PYTORCH_INDEX_URL="https://download.pytorch.org/whl/cpu"
    fi
    echo -e "${INFO}Installing PyTorch from ${PYTORCH_INDEX_URL}..."
    run_pip_quiet torch torchaudio --index-url "${PYTORCH_INDEX_URL}"
    echo -e "${SUCCESS}PyTorch Installed."
fi

echo -e "${INFO}Installing Python dependencies from requirements files..."
# --- OPTIMIZATION: Combined uv pip install from previous version is retained ---
run_pip_quiet -r extra-req.txt -r requirements.txt
echo -e "${SUCCESS}Python dependencies installed."

# --- PHASE 5: Post-Install Configuration ---
if [ -f "open_jtalk_dic_utf_8-1.11.tar.gz" ]; then
    echo -e "${INFO}Unpacking Open JTalk Dictionary..."
    PYOPENJTALK_PREFIX=$(python -c "import os, pyopenjtalk; print(os.path.dirname(pyopenjtalk.__file__))")
    tar -xzf open_jtalk_dic_utf_8-1.11.tar.gz -C "$PYOPENJTALK_PREFIX" && rm open_jtalk_dic_utf_8-1.11.tar.gz
    echo -e "${SUCCESS}Open JTalk Dictionary configured."
fi

if [ "$USE_ROCM" = true ] && [ "$IS_WSL" = true ]; then
    echo -e "${INFO}Applying WSL compatibility fix for ROCm..."
    location=$(uv pip show torch | grep Location | awk -F ": " '{print $2}')
    cd "${location}"/torch/lib/ || exit
    rm -f libhsa-runtime64.so*
    cp "$(readlink -f /opt/rocm/lib/libhsa-runtime64.so)" libhsa-runtime64.so
    echo -e "${SUCCESS}ROCm fix applied."
fi

echo -e "${SUCCESS}${BOLD}Installation has completed successfully!${RESET}"
