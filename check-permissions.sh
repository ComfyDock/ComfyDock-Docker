#!/usr/bin/env bash
# Script to check permissions on bind-mounted volumes
# Creates /tmp/problem-files.txt and /tmp/problem-dirs.txt for problematic permissions

set -e

# Get the comfy user's UID/GID (either default or remapped)
COMFY_UID=${WANTED_UID:-1000}
COMFY_GID=${WANTED_GID:-1000}

# Configure parallel processing
PARALLEL_JOBS=${PERMISSION_CHECK_PARALLEL_JOBS:-4}
FILES_PER_BATCH=${PERMISSION_CHECK_FILES_PER_BATCH:-20}
DIRS_PER_BATCH=${PERMISSION_CHECK_DIRS_PER_BATCH:-10}

echo "Checking permissions for user comfy (UID=$COMFY_UID, GID=$COMFY_GID)"
echo "Using $PARALLEL_JOBS parallel processes"

# Clear previous problem files
> /tmp/problem-files.txt
> /tmp/problem-dirs.txt

# Function to detect bind mounts
detect_bind_mounts() {
    # Parse /proc/self/mountinfo to find bind mounts
    # Format: mount_id parent_id major:minor root mount_point options...
    while IFS= read -r line; do
        # Extract mount point (5th field after splitting by space)
        mount_point=$(echo "$line" | awk '{print $5}')
        
        # Skip system mounts
        if [[ "$mount_point" =~ ^/(proc|sys|dev|etc|usr|bin|sbin|lib|lib64|var|run|tmp)(/|$) ]]; then
            continue
        fi
        
        # Check if it's inside /app (where ComfyUI lives) or /home
        if [[ "$mount_point" =~ ^/app/ ]] || [[ "$mount_point" =~ ^/home/ ]]; then
            echo "$mount_point"
        fi
    done < /proc/self/mountinfo
}

# Function to check if a path is readable/writable by comfy user
check_permissions() {
    local path="$1"
    local type="$2"  # "file" or "dir"
    
    # Get file/directory ownership
    local file_uid=$(stat -c '%u' "$path" 2>/dev/null)
    local file_gid=$(stat -c '%g' "$path" 2>/dev/null)
    
    # If already owned by comfy user, no problem
    if [ "$file_uid" = "$COMFY_UID" ] && [ "$file_gid" = "$COMFY_GID" ]; then
        return 0
    fi
    
    # Not owned by comfy user, so test if we can read/write to it
    if ! su comfy -c "test -r '$path' && test -w '$path'" 2>/dev/null; then
        if [ "$type" = "file" ]; then
            echo "$path" >> /tmp/problem-files.txt
        else
            echo "$path" >> /tmp/problem-dirs.txt
        fi
        return 1
    fi
    return 0
}

# Function to check a batch of files in parallel
check_file_batch() {
    local temp_file="/tmp/problem-files-$$-$(date +%s%N).tmp"
    
    for file in "$@"; do
        if [ -f "$file" ]; then
            # Get file ownership
            local file_uid=$(stat -c '%u' "$file" 2>/dev/null)
            local file_gid=$(stat -c '%g' "$file" 2>/dev/null)
            
            # If already owned by comfy user, no problem
            if [ "$file_uid" = "$COMFY_UID" ] && [ "$file_gid" = "$COMFY_GID" ]; then
                continue
            fi
            
            # Not owned by comfy user, so test if we can read/write to it
            if ! su comfy -c "test -r '$file' && test -w '$file'" 2>/dev/null; then
                echo "$file" >> "$temp_file"
            fi
        fi
    done
    
    # Append to main problem file if we found any issues
    if [ -s "$temp_file" ]; then
        cat "$temp_file" >> /tmp/problem-files.txt
    fi
    rm -f "$temp_file"
}

# Function to check a batch of directories in parallel
check_dir_batch() {
    local temp_file="/tmp/problem-dirs-$$-$(date +%s%N).tmp"
    
    for dir in "$@"; do
        if [ -d "$dir" ]; then
            # Get directory ownership
            local dir_uid=$(stat -c '%u' "$dir" 2>/dev/null)
            local dir_gid=$(stat -c '%g' "$dir" 2>/dev/null)
            
            # If already owned by comfy user, no problem
            if [ "$dir_uid" = "$COMFY_UID" ] && [ "$dir_gid" = "$COMFY_GID" ]; then
                continue
            fi
            
            # Not owned by comfy user, so test if we can read/write to it
            if ! su comfy -c "test -r '$dir' && test -w '$dir'" 2>/dev/null; then
                echo "$dir" >> "$temp_file"
            fi
        fi
    done
    
    # Append to main problem file if we found any issues
    if [ -s "$temp_file" ]; then
        cat "$temp_file" >> /tmp/problem-dirs.txt
    fi
    rm -f "$temp_file"
}

# Export functions and variables for parallel processing
export -f check_file_batch check_dir_batch
export COMFY_UID COMFY_GID PARALLEL_JOBS FILES_PER_BATCH DIRS_PER_BATCH

# Function to check directory permissions with parallel processing
check_directory() {
    local dir="$1"
    
    # echo "  Scanning directory structure..."
    
    # Get all files and directories at once, excluding symlinks
    # Use -print0 and xargs -0 to handle filenames with spaces and special characters
    
    # echo "  Scanning for files..."
    local temp_files="/tmp/files-$$-$(date +%s%N).list"
    find "$dir" -type f -print0 2>/dev/null | head -c 1000000 > "$temp_files"  # Limit file list size
    
    if [ -s "$temp_files" ]; then
        local file_count=$(tr '\0' '\n' < "$temp_files" | wc -l)
        # echo "  Checking $file_count files in parallel..."
        cat "$temp_files" | xargs -0 -n "$FILES_PER_BATCH" -P "$PARALLEL_JOBS" bash -c 'check_file_batch "$@"' _
    fi
    rm -f "$temp_files"
    
    # echo "  Scanning for directories..."
    local temp_dirs="/tmp/dirs-$$-$(date +%s%N).list"
    find "$dir" -type d -print0 2>/dev/null | head -c 500000 > "$temp_dirs"  # Limit dir list size
    
    if [ -s "$temp_dirs" ]; then
        local dir_count=$(tr '\0' '\n' < "$temp_dirs" | wc -l)
        # echo "  Checking $dir_count directories in parallel..."
        cat "$temp_dirs" | xargs -0 -n "$DIRS_PER_BATCH" -P "$PARALLEL_JOBS" bash -c 'check_dir_batch "$@"' _
    fi
    rm -f "$temp_dirs"
}

# Define all ComfyUI directories we want to check
COMFY_DIRS=(
    "/app/ComfyUI/custom_nodes"
    "/app/ComfyUI/web/extensions"
    "/app/ComfyUI/models"
    "/app/ComfyUI/input"
    "/app/ComfyUI/output"
    "/app/ComfyUI/user"
)

# Track which directories we've already checked
declare -A CHECKED_DIRS

# Main execution
echo "Detecting bind-mounted volumes..."
BIND_MOUNTS=$(detect_bind_mounts | sort -u)

if [ -z "$BIND_MOUNTS" ]; then
    echo "No bind mounts detected in /app or /home directories"
else
    echo "Found bind mounts:"
    echo "$BIND_MOUNTS"
    echo ""
    echo "Checking permissions on bind-mounted volumes..."
    
    # Check each bind mount and mark as checked
    while IFS= read -r mount; do
        if [ -d "$mount" ]; then
            echo "Checking: $mount"
            check_directory "$mount"
            # Mark this directory and any parent/child relationships as checked
            CHECKED_DIRS["$mount"]=1
        fi
    done <<< "$BIND_MOUNTS"
fi

# Check remaining ComfyUI directories that weren't already checked as bind mounts
echo ""
echo "Checking ComfyUI directories..."
for dir in "${COMFY_DIRS[@]}"; do
    if [ -d "$dir" ]; then
        # Check if this directory was already processed as a bind mount
        already_checked=false
        
        # Check if this exact directory was already checked
        if [[ -n "${CHECKED_DIRS[$dir]:-}" ]]; then
            already_checked=true
        else
            # Check if this directory is a subdirectory of any checked bind mount
            for checked_dir in "${!CHECKED_DIRS[@]}"; do
                if [[ "$dir" == "$checked_dir"/* ]]; then
                    already_checked=true
                    break
                fi
            done
        fi
        
        if [ "$already_checked" = false ]; then
            echo "Checking: $dir"
            check_directory "$dir"
            CHECKED_DIRS["$dir"]=1
        else
            echo "Skipping $dir (already checked as bind mount)"
        fi
    else
        echo "Directory not found: $dir"
    fi
done

# Report results
echo ""
echo "Permission check complete!"

if [ -s /tmp/problem-files.txt ]; then
    echo "❌ Found $(wc -l < /tmp/problem-files.txt) files with permission issues"
    echo "   See: /tmp/problem-files.txt"
else
    echo "✅ No file permission issues found"
    rm -f /tmp/problem-files.txt
fi

if [ -s /tmp/problem-dirs.txt ]; then
    echo "❌ Found $(wc -l < /tmp/problem-dirs.txt) directories with permission issues"
    echo "   See: /tmp/problem-dirs.txt"
else
    echo "✅ No directory permission issues found"
    rm -f /tmp/problem-dirs.txt
fi

# Optional: Create a summary file
if [ -s /tmp/problem-files.txt ] || [ -s /tmp/problem-dirs.txt ]; then
    {
        echo "Permission Issues Summary"
        echo "========================="
        echo "User: comfy (UID=$COMFY_UID, GID=$COMFY_GID)"
        echo "Timestamp: $(date)"
        echo ""
        
        if [ -s /tmp/problem-dirs.txt ]; then
            echo "Problematic Directories:"
            cat /tmp/problem-dirs.txt | sed 's/^/  - /'
            echo ""
        fi
        
        if [ -s /tmp/problem-files.txt ]; then
            echo "Problematic Files:"
            cat /tmp/problem-files.txt | sed 's/^/  - /'
        fi
    } > /tmp/permission-issues-summary.txt
    
    echo ""
    echo "📄 Full summary available at: /tmp/permission-issues-summary.txt"
fi