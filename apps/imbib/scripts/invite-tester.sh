#!/bin/bash
#
# Invite a beta tester to TestFlight
# Uses App Store Connect API to programmatically add testers
#
# Usage: ./scripts/invite-tester.sh <email> <first-name> <last-name>
#
# Example: ./scripts/invite-tester.sh john@example.com John Doe
#
# Prerequisites:
# - App Store Connect API credentials (run appstore-release.sh --setup)
# - jq installed (brew install jq)
#
# The tester will receive an email invitation to join TestFlight.
#

set -e

# Keychain service names
KEYCHAIN_SERVICE="imbib-testflight"
KEYCHAIN_SERVICE_RELEASE="imbib-release"

# App bundle IDs
IOS_BUNDLE_ID="com.imbib.app.ios"
MACOS_BUNDLE_ID="com.imbib.app"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ============================================================================
# Help
# ============================================================================
show_help() {
    echo "Usage: $0 <email> <first-name> <last-name>"
    echo ""
    echo "Invite a beta tester to TestFlight for imbib (iOS and macOS)."
    echo ""
    echo "Arguments:"
    echo "  email       Tester's email address"
    echo "  first-name  Tester's first name"
    echo "  last-name   Tester's last name"
    echo ""
    echo "Examples:"
    echo "  $0 john@example.com John Doe"
    echo "  $0 jane.smith@gmail.com Jane Smith"
    echo ""
    echo "Options:"
    echo "  --list-groups    List available beta groups"
    echo "  --list-testers   List current beta testers"
    echo "  --list-builds    List recent builds and their status"
    echo ""
    exit 0
}

if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    show_help
fi

# Check for list options early (before argument validation)
LIST_MODE=""
if [[ "$1" == "--list-groups" ]]; then
    LIST_MODE="groups"
elif [[ "$1" == "--list-testers" ]]; then
    LIST_MODE="testers"
elif [[ "$1" == "--list-builds" ]]; then
    LIST_MODE="builds"
elif [[ $# -lt 3 ]]; then
    show_help
fi

# ============================================================================
# Retrieve credentials from Keychain
# ============================================================================
get_credential() {
    local account="$1"
    local service="$2"
    security find-generic-password -a "$account" -s "$service" -w 2>/dev/null || true
}

ASC_KEY_ID=$(get_credential "asc-key-id" "$KEYCHAIN_SERVICE")
ASC_ISSUER_ID=$(get_credential "asc-issuer-id" "$KEYCHAIN_SERVICE")

# Check credentials
if [ -z "$ASC_KEY_ID" ] || [ -z "$ASC_ISSUER_ID" ]; then
    echo -e "${RED}Missing App Store Connect credentials${NC}"
    echo "Run: ./scripts/appstore-release.sh --setup"
    exit 1
fi

# Check for API key file
API_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
if [ ! -f "$API_KEY_PATH" ]; then
    echo -e "${RED}API key file not found: $API_KEY_PATH${NC}"
    exit 1
fi

# Check for jq
command -v jq >/dev/null 2>&1 || { echo -e "${RED}jq is required. Install with: brew install jq${NC}"; exit 1; }

# ============================================================================
# Generate JWT token for App Store Connect API
# ============================================================================
# Note: ES256 requires raw R||S signature format, not DER. Using Ruby for proper handling.
generate_jwt() {
    local key_id="$1"
    local issuer_id="$2"
    local key_path="$3"

    ruby -e '
require "openssl"
require "base64"
require "json"

key_id = ARGV[0]
issuer_id = ARGV[1]
key_path = ARGV[2]

key = OpenSSL::PKey::EC.new(File.read(key_path))

header = Base64.urlsafe_encode64({"alg" => "ES256", "kid" => key_id, "typ" => "JWT"}.to_json, padding: false)
payload = Base64.urlsafe_encode64({
  "iss" => issuer_id,
  "iat" => Time.now.to_i,
  "exp" => Time.now.to_i + 1200,
  "aud" => "appstoreconnect-v1"
}.to_json, padding: false)

signing_input = "#{header}.#{payload}"
signature_der = key.sign(OpenSSL::Digest::SHA256.new, signing_input)

# Convert DER to raw R||S format (each 32 bytes for P-256)
asn1 = OpenSSL::ASN1.decode(signature_der)
r = asn1.value[0].value.to_s(2).rjust(32, "\x00")[-32..-1]
s = asn1.value[1].value.to_s(2).rjust(32, "\x00")[-32..-1]
signature = Base64.urlsafe_encode64(r + s, padding: false)

puts "#{header}.#{payload}.#{signature}"
' "$key_id" "$issuer_id" "$key_path"
}

JWT_TOKEN=$(generate_jwt "$ASC_KEY_ID" "$ASC_ISSUER_ID" "$API_KEY_PATH")
AUTH_HEADER="Authorization: Bearer $JWT_TOKEN"
API_BASE="https://api.appstoreconnect.apple.com/v1"

# ============================================================================
# List beta groups
# ============================================================================
if [[ "$LIST_MODE" == "groups" ]]; then
    echo -e "${BLUE}Fetching beta groups...${NC}"

    response=$(curl -s -H "$AUTH_HEADER" "$API_BASE/betaGroups?limit=50")

    if echo "$response" | jq -e '.errors' > /dev/null 2>&1; then
        echo -e "${RED}Error:${NC}"
        echo "$response" | jq '.errors[0].detail'
        exit 1
    fi

    echo ""
    echo -e "${GREEN}Beta Groups:${NC}"
    echo "$response" | jq -r '.data[] | "  \(.id): \(.attributes.name) (\(.attributes.publicLinkEnabled // false | if . then "public link enabled" else "invite only" end))"'
    exit 0
fi

# ============================================================================
# List beta testers
# ============================================================================
if [[ "$LIST_MODE" == "testers" ]]; then
    echo -e "${BLUE}Fetching beta testers...${NC}"

    response=$(curl -s -H "$AUTH_HEADER" "$API_BASE/betaTesters?limit=100")

    if echo "$response" | jq -e '.errors' > /dev/null 2>&1; then
        echo -e "${RED}Error:${NC}"
        echo "$response" | jq '.errors[0].detail'
        exit 1
    fi

    echo ""
    echo -e "${GREEN}Beta Testers:${NC}"
    echo "$response" | jq -r '.data[] | "  \(.attributes.email) - \(.attributes.firstName) \(.attributes.lastName) (\(.attributes.inviteType))"'
    exit 0
fi

# ============================================================================
# List builds
# ============================================================================
if [[ "$LIST_MODE" == "builds" ]]; then
    echo -e "${BLUE}Fetching apps and builds...${NC}"

    # Get all apps
    apps_response=$(curl -s -H "$AUTH_HEADER" "$API_BASE/apps?limit=50")

    if echo "$apps_response" | jq -e '.errors' > /dev/null 2>&1; then
        echo -e "${RED}Error:${NC}"
        echo "$apps_response" | jq '.errors[0].detail'
        exit 1
    fi

    echo ""
    echo -e "${GREEN}Apps:${NC}"
    echo "$apps_response" | jq -r '.data[] | "  \(.id): \(.attributes.bundleId) - \(.attributes.name)"'

    # Get recent builds
    echo ""
    echo -e "${GREEN}Recent Builds:${NC}"
    builds_response=$(curl -s -H "$AUTH_HEADER" "$API_BASE/builds?limit=20&sort=-uploadedDate&include=app")

    if echo "$builds_response" | jq -e '.errors' > /dev/null 2>&1; then
        echo -e "${RED}Error fetching builds:${NC}"
        echo "$builds_response" | jq '.errors[0].detail'
    else
        echo "$builds_response" | jq -r '.data[] | "  \(.attributes.version) (\(.attributes.uploadedDate)) - \(.attributes.processingState) - \(.attributes.minOsVersion // "N/A")"'

        # Show if there are no builds
        count=$(echo "$builds_response" | jq '.data | length')
        if [[ "$count" == "0" ]]; then
            echo -e "  ${YELLOW}No builds found${NC}"
        fi
    fi
    exit 0
fi

# ============================================================================
# Invite tester
# ============================================================================
EMAIL="$1"
FIRST_NAME="$2"
LAST_NAME="$3"

echo -e "${GREEN}=== Invite Beta Tester ===${NC}"
echo -e "Email:      ${YELLOW}$EMAIL${NC}"
echo -e "Name:       ${YELLOW}$FIRST_NAME $LAST_NAME${NC}"
echo ""

# First, get the app IDs
echo -e "${BLUE}Looking up apps...${NC}"

# Get all apps and filter by exact bundle ID match
# (API filter does prefix matching, so we need exact match in jq)
apps_response=$(curl -s -H "$AUTH_HEADER" "$API_BASE/apps?limit=50")

IOS_APP_ID=$(echo "$apps_response" | jq -r --arg bid "$IOS_BUNDLE_ID" '.data[] | select(.attributes.bundleId == $bid) | .id' | head -1)
MACOS_APP_ID=$(echo "$apps_response" | jq -r --arg bid "$MACOS_BUNDLE_ID" '.data[] | select(.attributes.bundleId == $bid) | .id' | head -1)

if [ -z "$IOS_APP_ID" ] && [ -z "$MACOS_APP_ID" ]; then
    echo -e "${RED}No apps found. Make sure you've uploaded at least one build.${NC}"
    exit 1
fi

echo -e "  iOS App ID:   ${GREEN}${IOS_APP_ID:-not found}${NC}"
echo -e "  macOS App ID: ${GREEN}${MACOS_APP_ID:-not found}${NC}"

# Get all beta groups
echo -e "${BLUE}Finding beta groups...${NC}"
groups_response=$(curl -s -H "$AUTH_HEADER" "$API_BASE/betaGroups?limit=50&include=app")

# ============================================================================
# Helper function to get or create beta group for an app
# ============================================================================
get_or_create_beta_group() {
    local app_id="$1"
    local platform_name="$2"
    local group_name="Beta Testers"

    # Find existing group for this app
    local group_id=$(echo "$groups_response" | jq -r --arg app_id "$app_id" \
        '.data[] | select(.attributes.name == "Beta Testers" and .relationships.app.data.id == $app_id) | .id' | head -1)

    if [ -z "$group_id" ]; then
        echo -e "  Creating '$group_name' group for $platform_name..." >&2

        local create_response=$(curl -s -X POST -H "$AUTH_HEADER" -H "Content-Type: application/json" \
            "$API_BASE/betaGroups" \
            -d "{
                \"data\": {
                    \"type\": \"betaGroups\",
                    \"attributes\": {
                        \"name\": \"$group_name\",
                        \"publicLinkEnabled\": false,
                        \"publicLinkLimitEnabled\": false,
                        \"feedbackEnabled\": true
                    },
                    \"relationships\": {
                        \"app\": {
                            \"data\": {
                                \"type\": \"apps\",
                                \"id\": \"$app_id\"
                            }
                        }
                    }
                }
            }")

        if echo "$create_response" | jq -e '.errors' > /dev/null 2>&1; then
            echo -e "${RED}Failed to create $platform_name beta group:${NC}" >&2
            echo "$create_response" | jq -r '.errors[0].detail' >&2
            echo ""
            return
        fi

        group_id=$(echo "$create_response" | jq -r '.data.id')
    fi

    echo "$group_id"
}

# ============================================================================
# Helper function to add tester to a beta group
# ============================================================================
add_tester_to_group() {
    local group_id="$1"
    local platform_name="$2"
    local tester_id="$3"

    if [ -z "$group_id" ]; then
        return
    fi

    local add_response=$(curl -s -X POST -H "$AUTH_HEADER" -H "Content-Type: application/json" \
        "$API_BASE/betaGroups/$group_id/relationships/betaTesters" \
        -d "{
            \"data\": [
                {
                    \"type\": \"betaTesters\",
                    \"id\": \"$tester_id\"
                }
            ]
        }")

    # Check for errors (but ignore "already in group" errors)
    if echo "$add_response" | jq -e '.errors' > /dev/null 2>&1; then
        local error_detail=$(echo "$add_response" | jq -r '.errors[0].detail // "Unknown error"')
        # "cannot be assigned" means already in the group
        if [[ "$error_detail" == *"already"* ]] || [[ "$error_detail" == *"cannot be assigned"* ]]; then
            echo -e "  ${GREEN}✓ Already in $platform_name beta group${NC}"
        else
            echo -e "  ${YELLOW}Warning: Could not add to $platform_name group: $error_detail${NC}"
        fi
    else
        echo -e "  ${GREEN}✓ Added to $platform_name beta group${NC}"
    fi
}

# Get or create beta groups for each platform
IOS_BETA_GROUP_ID=""
MACOS_BETA_GROUP_ID=""

if [ -n "$IOS_APP_ID" ]; then
    IOS_BETA_GROUP_ID=$(get_or_create_beta_group "$IOS_APP_ID" "iOS")
    if [ -n "$IOS_BETA_GROUP_ID" ]; then
        echo -e "  iOS Beta Group ID:   ${GREEN}$IOS_BETA_GROUP_ID${NC}"
    fi
fi

if [ -n "$MACOS_APP_ID" ]; then
    MACOS_BETA_GROUP_ID=$(get_or_create_beta_group "$MACOS_APP_ID" "macOS")
    if [ -n "$MACOS_BETA_GROUP_ID" ]; then
        echo -e "  macOS Beta Group ID: ${GREEN}$MACOS_BETA_GROUP_ID${NC}"
    fi
fi

if [ -z "$IOS_BETA_GROUP_ID" ] && [ -z "$MACOS_BETA_GROUP_ID" ]; then
    echo -e "${RED}Failed to get or create any beta groups${NC}"
    exit 1
fi

# Determine primary group (create tester with first group, then add to others)
# API only allows one betaGroup relationship when creating a tester
PRIMARY_GROUP_ID=""
PRIMARY_PLATFORM=""
SECONDARY_GROUP_ID=""
SECONDARY_PLATFORM=""

if [ -n "$IOS_BETA_GROUP_ID" ]; then
    PRIMARY_GROUP_ID="$IOS_BETA_GROUP_ID"
    PRIMARY_PLATFORM="iOS"
    if [ -n "$MACOS_BETA_GROUP_ID" ]; then
        SECONDARY_GROUP_ID="$MACOS_BETA_GROUP_ID"
        SECONDARY_PLATFORM="macOS"
    fi
elif [ -n "$MACOS_BETA_GROUP_ID" ]; then
    PRIMARY_GROUP_ID="$MACOS_BETA_GROUP_ID"
    PRIMARY_PLATFORM="macOS"
fi

# Create the beta tester (with primary group only - API limitation)
echo -e "${BLUE}Creating beta tester invitation...${NC}"

create_tester_response=$(curl -s -X POST -H "$AUTH_HEADER" -H "Content-Type: application/json" \
    "$API_BASE/betaTesters" \
    -d "{
        \"data\": {
            \"type\": \"betaTesters\",
            \"attributes\": {
                \"email\": \"$EMAIL\",
                \"firstName\": \"$FIRST_NAME\",
                \"lastName\": \"$LAST_NAME\"
            },
            \"relationships\": {
                \"betaGroups\": {
                    \"data\": [
                        {
                            \"type\": \"betaGroups\",
                            \"id\": \"$PRIMARY_GROUP_ID\"
                        }
                    ]
                }
            }
        }
    }")

if echo "$create_tester_response" | jq -e '.errors' > /dev/null 2>&1; then
    error_detail=$(echo "$create_tester_response" | jq -r '.errors[0].detail')

    # Check if tester already exists or cannot be assigned (already in system)
    if [[ "$error_detail" == *"already exists"* ]] || [[ "$error_detail" == *"already been added"* ]] || [[ "$error_detail" == *"cannot be assigned"* ]]; then
        echo -e "${YELLOW}Tester already exists, adding to groups...${NC}"

        # Find existing tester
        existing_response=$(curl -s -H "$AUTH_HEADER" "$API_BASE/betaTesters?filter%5Bemail%5D=$EMAIL")
        TESTER_ID=$(echo "$existing_response" | jq -r '.data[0].id // empty')

        if [ -n "$TESTER_ID" ]; then
            # Add to both groups
            add_tester_to_group "$IOS_BETA_GROUP_ID" "iOS" "$TESTER_ID"
            add_tester_to_group "$MACOS_BETA_GROUP_ID" "macOS" "$TESTER_ID"
        else
            echo -e "${RED}Could not find existing tester${NC}"
            exit 1
        fi
    else
        echo -e "${RED}Failed to create beta tester:${NC}"
        echo "$error_detail"
        exit 1
    fi
else
    TESTER_ID=$(echo "$create_tester_response" | jq -r '.data.id')
    echo -e "${GREEN}✓ Beta tester created: $TESTER_ID${NC}"
    echo -e "  ${GREEN}✓ Added to $PRIMARY_PLATFORM beta${NC}"

    # Add to secondary group if exists
    if [ -n "$SECONDARY_GROUP_ID" ]; then
        add_tester_to_group "$SECONDARY_GROUP_ID" "$SECONDARY_PLATFORM" "$TESTER_ID"
    fi
fi

echo ""
echo -e "${GREEN}=== Invitation Sent ===${NC}"
echo ""
echo -e "$FIRST_NAME $LAST_NAME ($EMAIL) will receive:"
if [ -n "$IOS_BETA_GROUP_ID" ] && [ -n "$MACOS_BETA_GROUP_ID" ]; then
    echo "  - iOS TestFlight invitation"
    echo "  - macOS TestFlight invitation"
elif [ -n "$IOS_BETA_GROUP_ID" ]; then
    echo "  - iOS TestFlight invitation"
else
    echo "  - macOS TestFlight invitation"
fi
echo ""
echo -e "${BLUE}Note:${NC} External testers will only receive an email once a build is:"
echo "  1. Submitted for Beta App Review (in App Store Connect)"
echo "  2. Approved by Apple (24-48 hours for first submission)"
echo "  3. Added to the 'Beta Testers' group"
echo ""
