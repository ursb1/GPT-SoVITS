#!/bin/bash

# cd into GPT-SoVITS Base Path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

cd "$SCRIPT_DIR" || exit 1

RESET="\033[0m"
BOLD="\033[1m"
ERROR="\033[1;31m[ERROR]: $RESET"
WARNING="\033[1;33m[WARNING]: $RESET"
INFO="\033[1;32m[INFO]: $RESET"
SUCCESS="\033[1;34m[SUCCESS]: $RESET"

set -eE
set -o errtrace

trap 'on_error $LINENO "$BASH_COMMAND" $?' ERR

# shellcheck disable=SC2317
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

run_wget_quiet() {
    # This function is for foreground downloads with a progress bar
    if wget --tries=25 --wait=5 --read-timeout=40 -q --show-progress "$@" 2>&1; then
        tput cuu1 && tput el
    else
        echo -e "${ERROR} Wget failed for URL: $2"
        exit 1
    fi
}

run_wget_parallel() {
    # This function is for background downloads (no progress bar)
    if ! wget --tries=25 --wait=5 --read-timeout=40 -q -O "$1" "$2" 2>&1; then
        echo -e "${ERROR} Parallel Wget failed for URL: $2"
        # Since this runs in the background, we create a failure marker file
        touch "download.failed"
    fi
}


if ! command -v conda &>/dev/null; then
    echo -e "${ERROR}Conda Not Found"
    exit 1
fi

# --- OPTIMIZATION: Check for uv upfront ---
if ! command -v uv &>/dev/null; then
    echo -e "${ERROR}uv Not Found. Please install it first: 'pip install uv'"
    exit 1
fi

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

# Show help if no arguments provided
if [[ $# -eq 0 ]]; then
    print_help
    exit 0
fi

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
    --source)
        case "$2" in
        HF)
            USE_HF=true
            ;;
        HF-Mirror)
            USE_HF_MIRROR=true
            ;;
        ModelScope)
            USE_MODELSCOPE=true
            ;;
        *)
            echo -e "${ERROR}Error: Invalid Download Source: $2"
            echo -e "${ERROR}Choose From: [HF, HF-Mirror, ModelScope]"
            exit 1
            ;;
        esac
        shift 2
        ;;
    --device)
        case "$2" in
        CU126)
            CUDA=126
            USE_CUDA=true
            ;;
        CU128)
            CUDA=128
            USE_CUDA=true
            ;;
        ROCM)
            USE_ROCM=true
            ;;
        MPS)
            USE_CPU=true
            ;;
        CPU)
            USE_CPU=true
            ;;
        *)
            echo -e "${ERROR}Error: Invalid Device: $2"
            echo -e "${ERROR}Choose From: [CU126, CU128, ROCM, MPS, CPU]"
            exit 1
            ;;
        esac
        shift 2
        ;;
    --download-uvr5)
        DOWNLOAD_UVR5=true
        shift
        ;;
    -h | --help)
        print_help
        exit 0
        ;;
    *)
        echo -e "${ERROR}Unknown Argument: $1"
        echo ""
        print_help
        exit 1
        ;;
    esac
done

if ! $USE_CUDA && ! $USE_ROCM && ! $USE_CPU; then
    echo -e "${ERROR}Error: Device is REQUIRED"
    echo ""
    print_help
    exit 1
fi

if ! $USE_HF && ! $USE_HF_MIRROR && ! $USE_MODELSCOPE; then
    echo -e "${ERROR}Error: Download Source is REQUIRED"
    echo ""
    print_help
    exit 1
fi

case "$(uname -m)" in
x86_64 | amd64) SYSROOT_PKG="sysroot_linux-64>=2.28" ;;
aarch64 | arm64) SYSROOT_PKG="sysroot_linux-aarch64>=2.28" ;;
ppc64le) SYSROOT_PKG="sysroot_linux-ppc64le>=2.28" ;;
*)
    echo "Unsupported architecture: $(uname -m)"
    exit 1
    ;;
esac

# Install build tools
echo -e "${INFO}Detected system: $(uname -s) $(uname -r) $(uname -m)"
if [ "$(uname)" != "Darwin" ]; then
    gcc_major_version=$(command -v gcc >/dev/null 2>&1 && gcc -dumpversion | cut -d. -f1 || echo 0)
    if [ "$gcc_major_version" -lt 11 ]; then
        echo -e "${INFO}Installing GCC & G++..."
        # --- OPTIMIZATION: Combined Conda installs ---
        run_conda_quiet gcc=11 gxx=11 "$SYSROOT_PKG"
        echo -e "${SUCCESS}GCC & G++ Installed..."
    else
        echo -e "${INFO}Detected GCC Version: $gcc_major_version"
        echo -e "${INFO}Skip Installing GCC & G++ From Conda-Forge"
        echo -e "${INFO}Installing libstdcxx-ng From Conda-Forge"
        run_conda_quiet "libstdcxx-ng>=$gcc_major_version"
        echo -e "${SUCCESS}libstdcxx-ng=$gcc_major_version Installed..."
    fi
else
    # macOS specific logic remains the same
    if ! xcode-select -p &>/dev/null; then
        echo -e "${INFO}Installing Xcode Command Line Tools..."
        xcode-select --install
        echo -e "${INFO}Waiting For Xcode Command Line Tools Installation Complete..."
        while true; do
            sleep 20
            if xcode-select -p &>/dev/null; then
                echo -e "${SUCCESS}Xcode Command Line Tools Installed"
                break
            else
                echo -e "${INFO}Installing，Please Wait..."
            fi
        done
    else
        XCODE_PATH=$(xcode-select -p)
        if [[ "$XCODE_PATH" == *"Xcode.app"* ]]; then
            echo -e "${WARNING} Detected Xcode path: $XCODE_PATH"
            echo -e "${WARNING} If your Xcode version does not match your macOS version, it may cause unexpected issues."
        fi
    fi
fi

# --- OPTIMIZATION: Combined Conda installs ---
echo -e "${INFO}Installing FFmpeg, CMake, make, unzip..."
run_conda_quiet ffmpeg cmake make unzip
echo -e "${SUCCESS}FFmpeg, CMake, make, unzip Installed"


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

PRETRINED_URL="$BASE_URL/pretrained_models.zip"
G2PW_URL="$BASE_URL/G2PWModel.zip"
UVR5_URL="$BASE_URL/uvr5_weights.zip"
NLTK_URL="$BASE_URL/nltk_data.zip"
PYOPENJTALK_URL="$BASE_URL/open_jtalk_dic_utf_8-1.11.tar.gz"

# --- OPTIMIZATION: Parallel Downloads ---
pids=() # Array to store background process IDs
rm -f download.failed # Clean up failure marker

echo -e "${INFO}Starting parallel download of models..."

if [ ! -d "GPT_SoVITS/pretrained_models/sv" ]; then
    echo -e "${INFO}  - Queuing Pretrained Models..."
    run_wget_parallel "pretrained_models.zip" "$PRETRINED_URL" &
    pids+=($!)
else
    echo -e "${INFO}  - Skipping Pretrained Models (already exists)"
fi

if [ ! -d "GPT_SoVITS/text/G2PWModel" ]; then
    echo -e "${INFO}  - Queuing G2PWModel..."
    run_wget_parallel "G2PWModel.zip" "$G2PW_URL" &
    pids+=($!)
else
    echo -e "${INFO}  - Skipping G2PWModel (already exists)"
fi

if [ "$DOWNLOAD_UVR5" = "true" ] && ! find -L "tools/uvr5/uvr5_weights" -mindepth 1 ! -name '.gitignore' | grep -q .; then
    echo -e "${INFO}  - Queuing UVR5 Models..."
    run_wget_parallel "uvr5_weights.zip" "$UVR5_URL" &
    pids+=($!)
else
    echo -e "${INFO}  - Skipping UVR5 Models (already exists or not requested)"
fi

# These are small and critical for Python dependencies, download them in parallel too
PY_PREFIX=$(python -c "import sys; print(sys.prefix)")
PYOPENJTALK_PREFIX=$(python -c "import os, pyopenjtalk; print(os.path.dirname(pyopenjtalk.__file__))" 2>/dev/null || echo "pyopenjtalk_placeholder")
echo -e "${INFO}  - Queuing NLTK Data..."
run_wget_parallel "nltk_data.zip" "$NLTK_URL" &
pids+=($!)
echo -e "${INFO}  - Queuing Open JTalk Dict..."
run_wget_parallel "open_jtalk_dic_utf_8-1.11.tar.gz" "$PYOPENJTALK_URL" &
pids+=($!)


echo -e "${INFO}Waiting for all downloads to complete..."
for pid in "${pids[@]}"; do
    wait "$pid"
done

if [ -f "download.failed" ]; then
    echo -e "${ERROR}One or more parallel downloads failed. Please check the logs."
    rm -f download.failed
    exit 1
fi
echo -e "${SUCCESS}All downloads completed."

# --- Unpack downloaded files sequentially ---
echo -e "${INFO}Unpacking downloaded files..."
if [ -f "pretrained_models.zip" ]; then
    unzip -q -o pretrained_models.zip -d GPT_SoVITS && rm pretrained_models.zip
    echo -e "${SUCCESS}Pretrained Models unpacked."
fi
if [ -f "G2PWModel.zip" ]; then
    unzip -q -o G2PWModel.zip -d GPT_SoVITS/text && rm G2PWModel.zip
    echo -e "${SUCCESS}G2PWModel unpacked."
fi
if [ -f "uvr5_weights.zip" ]; then
    unzip -q -o uvr5_weights.zip -d tools/uvr5 && rm uvr5_weights.zip
    echo -e "${SUCCESS}UVR5 Models unpacked."
fi
if [ -f "nltk_data.zip" ]; then
    unzip -q -o nltk_data.zip -d "$PY_PREFIX" && rm nltk_data.zip
    echo -e "${SUCCESS}NLTK Data unpacked."
fi
if [ -f "open_jtalk_dic_utf_8-1.11.tar.gz" ]; then
    if [ "$PYOPENJTALK_PREFIX" != "pyopenjtalk_placeholder" ]; then
         tar -xzf open_jtalk_dic_utf_8-1.11.tar.gz -C "$PYOPENJTALK_PREFIX" && rm open_jtalk_dic_utf_8-1.11.tar.gz
         echo -e "${SUCCESS}Open JTalk Dict unpacked."
    else
         echo -e "${WARNING}pyopenjtalk not installed yet. Cannot unpack dict. You may need to run this part manually later."
    fi
fi
# --- End of Parallel Downloads and Unpacking ---


# Hardware checks remain the same
if [ "$USE_CUDA" = true ] && [ "$WORKFLOW" = false ]; then
    echo -e "${INFO}Checking For Nvidia Driver Installation..."
    if command -v nvidia-smi &>/dev/null; then
        echo "${INFO}Nvidia Driver Founded"
    else
        echo -e "${WARNING}Nvidia Driver Not Found, Fallback to CPU"
        USE_CUDA=false
        USE_CPU=true
    fi
fi
if [ "$USE_ROCM" = true ] && [ "$WORKFLOW" = false ]; then
    echo -e "${INFO}Checking For ROCm Installation..."
    if [ -d "/opt/rocm" ]; then
        echo -e "${INFO}ROCm Founded"
        IS_WSL=$(grep -qi "microsoft" /proc/version && echo "true" || echo "false")
        if [ "$IS_WSL" = true ]; then echo -e "${INFO}WSL2 Founded"; fi
    else
        echo -e "${WARNING}ROCm Not Found, Fallback to CPU"
        USE_ROCM=false
        USE_CPU=true
    fi
fi


if [ "$USE_CUDA" = true ] && [ "$WORKFLOW" = false ]; then
    if [ "$CUDA" = 128 ]; then
        echo -e "${INFO}Installing PyTorch For CUDA 12.8..."
        run_pip_quiet torch torchaudio --index-url "https://download.pytorch.org/whl/cu128"
    elif [ "$CUDA" = 126 ]; then
        echo -e "${INFO}Installing PyTorch For CUDA 12.6..."
        run_pip_quiet torch torchaudio --index-url "https://download.pytorch.org/whl/cu126"
    fi
elif [ "$USE_ROCM" = true ] && [ "$WORKFLOW" = false ]; then
    echo -e "${INFO}Installing PyTorch For ROCm 6.2..."
    run_pip_quiet torch torchaudio --index-url "https://download.pytorch.org/whl/rocm6.2"
elif [ "$USE_CPU" = true ] && [ "$WORKFLOW" = false ]; then
    echo -e "${INFO}Installing PyTorch For CPU..."
    run_pip_quiet torch torchaudio --index-url "https://download.pytorch.org/whl/cpu"
elif [ "$WORKFLOW" = false ]; then
    echo -e "${ERROR}Unknown Err"
    exit 1
fi
echo -e "${SUCCESS}PyTorch Installed"

echo -e "${INFO}Installing Python Dependencies..."

hash -r

# --- OPTIMIZATION: Combined uv pip installs ---
run_pip_quiet -r extra-req.txt -r requirements.txt

echo -e "${SUCCESS}Python Dependencies Installed"


if [ "$USE_ROCM" = true ] && [ "$IS_WSL" = true ]; then
    echo -e "${INFO}Updating WSL Compatible Runtime Lib For ROCm..."
    location=$(uv pip show torch | grep Location | awk -F ": " '{print $2}')
    cd "${location}"/torch/lib/ || exit
    rm -f libhsa-runtime64.so*
    cp "$(readlink -f /opt/rocm/lib/libhsa-runtime64.so)" libhsa-runtime64.so
    echo -e "${SUCCESS}ROCm Runtime Lib Updated..."
fi

echo -e "${SUCCESS}${BOLD}Installation Completed Successfully!${RESET}"
