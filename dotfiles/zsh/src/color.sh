# Color management

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
CYAN="\033[0;36m"

NC="\033[0m" # No Color

function c_ok() {
    echo -e "${GREEN}$1${NC}"
}

function c_ko() {
    echo -e "${RED}$1${NC}"
}

function c_folder() {
    echo -e "${CYAN}$1${NC}"
}

function c_file() {
    echo -e "${YELLOW}$1${NC}"
}