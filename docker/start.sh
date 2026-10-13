#!/bin/bash
set -euo pipefail

#############################################
# Validate Environment Variables
#############################################
if [ -z "${VIDEO_URL:-}" ]; then
    echo "ERROR: VIDEO_URL is not set"
    exit 1
fi
if [ -z "${YOUTUBE_STREAM_KEY:-}" ]; then
    echo "ERROR: YOUTUBE_STREAM_KEY is not set"
    exit 1
fi

# Subscriber count + live viewer count are optional — if the API creds
# aren't provided, those elements just stay blank instead of failing
# the whole stream.
SHOW_STATS=true
if [ -z "${YOUTUBE_API_KEY:-}" ] || [ -z "${YOUTUBE_CHANNEL_ID:-}" ]; then
    echo "NOTICE: YOUTUBE_API_KEY / YOUTUBE_CHANNEL_ID not set — subscriber/viewer stats will be hidden."
    SHOW_STATS=false
fi

#############################################
# Output settings: 1080p @ 30 fps
#############################################
OUT_W=1920
OUT_H=1080
OUT_FPS=30
VIDEO_BITRATE="6000k"      # YouTube-recommended range for 1080p30 is ~4500-9000k
VIDEO_BUFSIZE="12000k"     # 2x bitrate
X264_PRESET="ultrafast"    # lightest preset — 1080p is heavy for a 2-core runner

echo "========================================"
echo "Starting 24/7 YouTube Stream — Black Holes"
echo "Output Resolution : ${OUT_W}x${OUT_H} (1080p)"
echo "FPS               : ${OUT_FPS}"
echo "Video bitrate     : ${VIDEO_BITRATE}"
echo "========================================"

FONT="font.ttf"
GOLD="0xE8A33D"
ASSET_DIR="panel_assets"
INFO_FILE="galaxy_info.txt"
SLOT=6            # seconds each headline is shown
FACT_SLOT=8       # seconds each fun fact is shown
CHANNEL_NAME="Technical Talk India"
# No background panels, so text gets a soft outline + shadow to stay
# readable on top of the video (sized for 1080p).
SHADOW="shadowcolor=black@0.8:shadowx=3:shadowy=3:borderw=3:bordercolor=black@0.55"
HEADLINE_FONTSIZE=32
HEADLINE_LINE_SPACING=14
HEADLINE_LINE_H=$((HEADLINE_FONTSIZE + HEADLINE_LINE_SPACING))

# Don't show "N watching now" until the live viewer count reaches this many.
VIEWER_MIN_TO_SHOW=10

# Approximate center + radius (in 1920x1080 output coordinates) of the
# subscribe icon baked into overlay.png; a pulsing gold ring is drawn
# around it. (overlay.png is scaled to the output size.)
SUB_ICON_X=1873
SUB_ICON_Y=1015
SUB_ICON_R=30

#############################################
# Auto-restart on failure
#############################################
MAX_RETRIES=5       # per-video retry attempts before moving on
RETRY_DELAY=5       # seconds between retries

mkdir -p "$ASSET_DIR"

#############################################
# Coordinate-label marker dot (ffmpeg input #2)
# 30x30: gold center, white ring.
#############################################
DOT_MARKER="dot_marker.png"
GOLD_R=232; GOLD_G=163; GOLD_B=61
DOT_VF="format=rgba,geq=r=(if(lte(hypot(X-15\,Y-15)\,8)\,${GOLD_R}\,if(lte(hypot(X-15\,Y-15)\,12)\,255\,0))):g=(if(lte(hypot(X-15\,Y-15)\,8)\,${GOLD_G}\,if(lte(hypot(X-15\,Y-15)\,12)\,255\,0))):b=(if(lte(hypot(X-15\,Y-15)\,8)\,${GOLD_B}\,if(lte(hypot(X-15\,Y-15)\,12)\,255\,0))):a=(if(lte(hypot(X-15\,Y-15)\,12)\,255\,0))"
ffmpeg -y -f lavfi -i "color=c=black@0.0:s=30x30" -vf "$DOT_VF" -frames:v 1 "$DOT_MARKER" -loglevel error || true
if [ ! -s "$DOT_MARKER" ]; then
    echo "WARNING: geq-based marker generation failed — using a blank 1x1 fallback."
    echo "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=" | base64 -d > "$DOT_MARKER"
fi

#############################################
# Background clock writer
#############################################
date -u +'%d %b %Y  •  %H:%M:%S UTC' > "$ASSET_DIR/clock.txt"
(
    while true; do
        date -u +'%d %b %Y  •  %H:%M:%S UTC' > "$ASSET_DIR/clock.txt.tmp"
        mv -f "$ASSET_DIR/clock.txt.tmp" "$ASSET_DIR/clock.txt"
        sleep 1
    done
) &
CLOCK_PID=$!

#############################################
# Background subscriber-count writer
#############################################
printf ' ' > "$ASSET_DIR/subs.txt"
SUBS_PID=""
if [ "$SHOW_STATS" = true ]; then
    (
        WARNED_ONCE=false
        while true; do
            RESP=$(curl -s "https://www.googleapis.com/youtube/v3/channels?part=statistics&id=${YOUTUBE_CHANNEL_ID}&key=${YOUTUBE_API_KEY}" || true)
            COUNT=$(echo "$RESP" | grep -o '"subscriberCount"[^"]*"[0-9]*"' | grep -oE '[0-9]+' || true)
            if [ -n "$COUNT" ]; then
                FORMATTED=$(echo "$COUNT" | rev | sed 's/\(...\)/\1,/g' | rev | sed 's/^,//')
                printf '%s subscribers' "$FORMATTED" > "$ASSET_DIR/subs.txt.tmp"
                mv -f "$ASSET_DIR/subs.txt.tmp" "$ASSET_DIR/subs.txt"
                WARNED_ONCE=false
            elif [ "$WARNED_ONCE" = false ]; then
                echo "WARNING: could not parse subscriberCount from API response. Raw response:"
                echo "$RESP"
                WARNED_ONCE=true
            fi
            sleep 60
        done
    ) &
    SUBS_PID=$!
fi

#############################################
# Background live-viewer-count writer
#############################################
printf ' ' > "$ASSET_DIR/viewers.txt"
VIEWERS_PID=""
if [ "$SHOW_STATS" = true ]; then
    (
        LIVE_VIDEO_ID=""
        while true; do
            if [ -z "$LIVE_VIDEO_ID" ]; then
                SEARCH_RESP=$(curl -s "https://www.googleapis.com/youtube/v3/search?part=id&channelId=${YOUTUBE_CHANNEL_ID}&eventType=live&type=video&key=${YOUTUBE_API_KEY}" || true)
                LIVE_VIDEO_ID=$(echo "$SEARCH_RESP" | grep -o '"videoId": *"[^"]*"' | head -1 | sed -E 's/.*"videoId": *"([^"]*)".*/\1/' || true)
            fi
            if [ -n "$LIVE_VIDEO_ID" ]; then
                VRESP=$(curl -s "https://www.googleapis.com/youtube/v3/videos?part=liveStreamingDetails&id=${LIVE_VIDEO_ID}&key=${YOUTUBE_API_KEY}" || true)
                VIEWERS=$(echo "$VRESP" | grep -o '"concurrentViewers": *"[0-9]*"' | grep -o '[0-9]*' || true)
                if [ -n "$VIEWERS" ] && [ "$VIEWERS" -ge "$VIEWER_MIN_TO_SHOW" ]; then
                    printf '%s watching now' "$VIEWERS" > "$ASSET_DIR/viewers.txt.tmp"
                    mv -f "$ASSET_DIR/viewers.txt.tmp" "$ASSET_DIR/viewers.txt"
                elif [ -n "$VIEWERS" ]; then
                    printf ' ' > "$ASSET_DIR/viewers.txt.tmp"
                    mv -f "$ASSET_DIR/viewers.txt.tmp" "$ASSET_DIR/viewers.txt"
                else
                    LIVE_VIDEO_ID=""
                    printf ' ' > "$ASSET_DIR/viewers.txt"
                fi
            fi
            sleep 30
        done
    ) &
    VIEWERS_PID=$!
fi

trap 'kill "$CLOCK_PID" 2>/dev/null || true; [ -n "$SUBS_PID" ] && kill "$SUBS_PID" 2>/dev/null || true; [ -n "$VIEWERS_PID" ] && kill "$VIEWERS_PID" 2>/dev/null || true' EXIT

#############################################
# Static text
#############################################
printf 'BLACK HOLES — LIVE'                  > "$ASSET_DIR/title1.txt"
printf 'B L A C K   H O L E   T R A C K E R' > "$ASSET_DIR/header.txt"
printf 'EVENT HORIZON · SINGULARITY · ACCRETION · GRAVITY' > "$ASSET_DIR/eyebrow.txt"
printf 'DID YOU KNOW'                        > "$ASSET_DIR/fact_label.txt"

#############################################
# Default headline / fact pools (used if
# galaxy_info.txt / facts.txt are missing)
#############################################
DEFAULT_HEADLINES=(
    "Exploring black holes live: event horizons, accretion disks, jets and gravitational waves."
    "A black hole is a region of space where gravity is so strong that nothing, not even light, can escape."
    "The event horizon is the point of no return around a black hole."
    "Stellar-mass black holes form when massive stars collapse at the end of their lives."
    "Supermassive black holes, millions to billions of times the Sun's mass, sit at the centers of most large galaxies."
    "Sagittarius A*, at the heart of our Milky Way, holds about 4 million times the mass of the Sun."
    "In 2019, the Event Horizon Telescope captured the first image of a black hole's shadow, in galaxy M87."
    "In 2022, astronomers revealed the first image of Sagittarius A*, the black hole at the center of our galaxy."
    "Matter spiraling into a black hole forms a superheated accretion disk that glows brightly in X-rays."
    "Some black holes launch jets of plasma at nearly the speed of light, stretching for thousands of light-years."
    "In 2015, LIGO made the first direct detection of gravitational waves, from two merging black holes."
    "Time runs slower near a black hole: the stronger the gravity, the slower the clock."
    "Hawking radiation predicts that black holes slowly lose energy and can eventually evaporate."
    "At the singularity, our current laws of physics break down."
    "Black holes do not roam space sucking everything in. Far away, their gravity acts like any object of the same mass."
)

DEFAULT_FACTS=(
    "A black hole's gravity is so strong that its escape velocity at the event horizon equals the speed of light."
    "The event horizon is the boundary beyond which nothing can return, not even light."
    "The Schwarzschild radius of the Sun would be only about 3 kilometers."
    "If Earth were squeezed into a black hole, it would be only about 9 millimeters across."
    "Karl Schwarzschild found the first exact black hole solution to Einstein's equations in 1916."
    "The term \"black hole\" was popularized by physicist John Wheeler in 1967."
    "Stellar-mass black holes typically weigh from a few to a few dozen times the mass of the Sun."
    "Supermassive black holes can weigh millions to billions of solar masses."
    "Sagittarius A* is about 26,000 light-years from Earth."
    "Sagittarius A* has about 4 million times the mass of the Sun."
    "M87* is about 55 million light-years away and holds roughly 6.5 billion solar masses."
    "The Event Horizon Telescope links radio dishes around the world into one Earth-sized telescope."
    "The 2020 Nobel Prize in Physics honored Roger Penrose, Reinhard Genzel and Andrea Ghez for black hole research."
    "Gaia BH1, about 1,560 light-years away, is one of the closest known black holes to Earth."
    "The Milky Way may contain tens of millions of stellar-mass black holes."
    "Cygnus X-1, discovered as an X-ray source, was one of the first strong black hole candidates."
    "Gas in an accretion disk can heat up to millions of degrees before falling in."
    "Quasars are the blazing cores of distant galaxies powered by feeding supermassive black holes."
    "Black hole jets can stretch far beyond their host galaxy."
    "Near a black hole, tidal forces can stretch objects, an effect called spaghettification."
    "Light can orbit a black hole at the photon sphere, about 1.5 times the horizon radius for a non-spinning one."
    "Spinning black holes drag space itself around with them, an effect called frame dragging."
    "The first gravitational waves seen, GW150914, came from two black holes merging about 1.3 billion light-years away."
    "LIGO, Virgo and KAGRA keep detecting black hole mergers through ripples in spacetime."
    "Stephen Hawking showed in 1974 that black holes should emit faint thermal radiation."
    "A black hole with the mass of the Sun would have a Hawking temperature far colder than the cosmic microwave background."
    "If the Sun became a black hole of the same mass, Earth would keep orbiting it as before."
    "Inside the event horizon, all paths lead toward the singularity."
    "A black hole's shadow appears about 2.5 times larger than its event horizon."
    "Intermediate-mass black holes, between stellar and supermassive, are rarer and harder to find."
    "Astronomers track stars orbiting Sagittarius A* to weigh the black hole at our galaxy's center."
    "Some black holes spin at a large fraction of the speed of light at their horizons."
)

#############################################
# build_labels_chain: optional per-video
# callout labels from <basename>.labels.txt
# (format: x,y,Label text).
#
# NOTE: x,y in the .labels.txt files are still
# given in 1280x720 coordinates (as before) and
# are scaled x1.5 here to the 1920x1080 frame,
# so existing label files keep working.
#############################################
build_labels_chain() {
    local url="$1"
    local base
    base="${url##*/}"
    base="${base%.*}"

    # `local` matters: the main loop uses a bare `i` too.
    local i idx

    LABELS_CHAIN=""
    LABELS_OUT="[base]"

    local labels_file="${base}.labels.txt"
    if [ ! -f "$labels_file" ]; then
        return 0
    fi

    local xs=() ys=() texts=()
    while IFS=',' read -r x y text; do
        x="$(echo "$x" | tr -d '[:space:]')"
        y="$(echo "$y" | tr -d '[:space:]')"
        text="$(echo "$text" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ "$x" =~ ^[0-9]+$ ]] || continue
        [[ "$y" =~ ^[0-9]+$ ]] || continue
        [ -z "$text" ] && continue
        # 720p -> 1080p
        xs+=("$((x * 3 / 2))"); ys+=("$((y * 3 / 2))"); texts+=("$text")
    done < "$labels_file"

    local n=${#xs[@]}
    if [ "$n" -eq 0 ]; then
        echo "NOTICE: $labels_file had no valid lines — skipping labels for this video."
        return 0
    fi
    echo "Using coordinate labels: $labels_file ($n label(s))"

    local BOX_H=63
    local V_OFFSET=105
    local H_OFFSET=60
    local ACCENT_W=6
    local BOX_GAP=15
    local LABEL_FONTSIZE=27
    local LABEL_PAD_L=21
    local LABEL_PAD_R=24
    local AVG_CHAR_W=15
    local BOX_W_MIN=165
    local BOX_W_MAX=390
    local placed_x=() placed_y=() placed_w=()
    local k collision tries

    local split_outs=""
    for ((i = 1; i <= n; i++)); do split_outs+="[dm${i}]"; done
    LABELS_CHAIN+="[2:v]split=${n}${split_outs};"

    local prev="base"
    for ((i = 0; i < n; i++)); do
        idx=$((i + 1))
        local x="${xs[$i]}" y="${ys[$i]}" text="${texts[$i]}"
        printf '%s' "$text" > "$ASSET_DIR/label${idx}.txt"

        local box_w=$(( ${#text} * AVG_CHAR_W + ACCENT_W + LABEL_PAD_L + LABEL_PAD_R ))
        [ "$box_w" -lt "$BOX_W_MIN" ] && box_w=$BOX_W_MIN
        [ "$box_w" -gt "$BOX_W_MAX" ] && box_w=$BOX_W_MAX

        local box_y=$((y - V_OFFSET))
        if [ "$box_y" -lt 30 ]; then
            box_y=$((y + V_OFFSET - BOX_H))
        fi
        local box_x=$((x + H_OFFSET))
        if [ $((box_x + box_w)) -gt 1890 ]; then
            box_x=$((x - H_OFFSET - box_w))
        fi
        [ "$box_x" -lt 0 ] && box_x=15

        tries=0
        while :; do
            collision=false
            for ((k = 0; k < ${#placed_x[@]}; k++)); do
                local px="${placed_x[$k]}" py="${placed_y[$k]}" pw="${placed_w[$k]}"
                if [ $((box_x)) -lt $((px + pw + BOX_GAP)) ] && \
                   [ $((box_x + box_w + BOX_GAP)) -gt $((px)) ] && \
                   [ $((box_y)) -lt $((py + BOX_H + BOX_GAP)) ] && \
                   [ $((box_y + BOX_H + BOX_GAP)) -gt $((py)) ]; then
                    collision=true
                    break
                fi
            done
            [ "$collision" = false ] && break
            box_y=$((box_y + BOX_H + BOX_GAP))
            if [ $((box_y + BOX_H)) -gt 1050 ]; then
                box_y=30
            fi
            tries=$((tries + 1))
            [ "$tries" -gt 12 ] && break
        done
        placed_x+=("$box_x")
        placed_y+=("$box_y")
        placed_w+=("$box_w")

        local seg_y_top seg_y_bot
        if [ "$box_y" -gt "$y" ]; then
            seg_y_top=$y; seg_y_bot=$box_y
        else
            seg_y_top=$box_y; seg_y_bot=$y
        fi
        local seg_h=$((seg_y_bot - seg_y_top))
        [ "$seg_h" -lt 3 ] && seg_h=3

        local h_left h_w
        if [ "$box_x" -gt "$x" ]; then
            h_left=$x; h_w=$((box_x - x))
        else
            h_left=$box_x; h_w=$((x - box_x))
        fi
        [ "$h_w" -lt 3 ] && h_w=3

        local n1="lbl${idx}_dot" n2="lbl${idx}_v" n3="lbl${idx}_h" n4="lbl${idx}_bg" n5="lbl${idx}_bar" n6="lbl${idx}_outline" n7="lbl${idx}_txt"

        LABELS_CHAIN+="[${prev}]drawbox=x=${x}:y=${seg_y_top}:w=3:h=${seg_h}:color=${GOLD}@0.85:t=fill[${n2}];"
        LABELS_CHAIN+="[${n2}]drawbox=x=${h_left}:y=${box_y}:w=${h_w}:h=3:color=${GOLD}@0.85:t=fill[${n3}];"
        LABELS_CHAIN+="[${n3}]drawbox=x=${box_x}:y=${box_y}:w=${box_w}:h=${BOX_H}:color=black@0.78:t=fill[${n4}];"
        LABELS_CHAIN+="[${n4}]drawbox=x=${box_x}:y=${box_y}:w=${ACCENT_W}:h=${BOX_H}:color=${GOLD}:t=fill[${n5}];"
        LABELS_CHAIN+="[${n5}]drawbox=x=${box_x}:y=${box_y}:w=${box_w}:h=${BOX_H}:color=${GOLD}@0.5:t=2[${n6}];"
        LABELS_CHAIN+="[${n6}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/label${idx}.txt:fontcolor=white:fontsize=${LABEL_FONTSIZE}:x=$((box_x + ACCENT_W + LABEL_PAD_L)):y=$((box_y + (BOX_H - LABEL_FONTSIZE) / 2)):${SHADOW}[${n7}];"
        # 30x30 marker, centered on the point
        LABELS_CHAIN+="[${n7}][dm${idx}]overlay=x=$((x - 15)):y=$((y - 15))[${n1}];"

        prev="$n1"
    done

    LABELS_OUT="[${prev}]"
    echo "Drew $n label(s) from $labels_file"
}

#############################################
# prepare_video_content: loads headlines +
# facts for the video about to stream and
# builds the filter chain (information text
# only — no side panel, no bottom bar).
#
# Per-video override files:
#   <basename>.headlines.txt / <basename>.facts.txt
#############################################
prepare_video_content() {
    local url="$1"
    local base
    base="${url##*/}"
    base="${base%.*}"

    # `local` matters: the main loop uses a bare `i` too.
    local i idx

    RAW_LINES=()
    if [ -f "${base}.headlines.txt" ]; then
        echo "Using curated headlines: ${base}.headlines.txt"
        while IFS= read -r line; do
            [ -n "$(echo "$line" | tr -d '[:space:]')" ] && RAW_LINES+=("$line")
        done < "${base}.headlines.txt"
    fi
    if [ "${#RAW_LINES[@]}" -eq 0 ]; then
        local pool=()
        if [ -f "$INFO_FILE" ]; then
            while IFS= read -r line; do
                [ -n "$(echo "$line" | tr -d '[:space:]')" ] && pool+=("$line")
            done < "$INFO_FILE"
        fi
        [ "${#pool[@]}" -eq 0 ] && pool=("${DEFAULT_HEADLINES[@]}")
        while IFS= read -r line; do
            RAW_LINES+=("$line")
        done < <(printf '%s\n' "${pool[@]}" | shuf)
    fi

    FACTS=()
    if [ -f "${base}.facts.txt" ]; then
        echo "Using curated facts: ${base}.facts.txt"
        while IFS= read -r line; do
            [ -n "$(echo "$line" | tr -d '[:space:]')" ] && FACTS+=("$line")
        done < "${base}.facts.txt"
    fi
    if [ "${#FACTS[@]}" -eq 0 ]; then
        local fpool=()
        if [ -f "facts.txt" ]; then
            while IFS= read -r line; do
                [ -n "$(echo "$line" | tr -d '[:space:]')" ] && fpool+=("$line")
            done < "facts.txt"
        fi
        [ "${#fpool[@]}" -eq 0 ] && fpool=("${DEFAULT_FACTS[@]}")
        while IFS= read -r line; do
            FACTS+=("$line")
        done < <(printf '%s\n' "${fpool[@]}" | shuf)
    fi

    N=${#RAW_LINES[@]}
    CYCLE=$((N * SLOT))
    echo "This video: $N headline(s), rotation cycle ${CYCLE}s"

    for i in "${!RAW_LINES[@]}"; do
        idx=$((i + 1))
        echo "${RAW_LINES[$i]}" | fold -s -w 25 > "$ASSET_DIR/headline${idx}.txt"
    done

    MAX_HEADLINE_LINES=1
    for i in "${!RAW_LINES[@]}"; do
        idx=$((i + 1))
        lines=$(grep -c '' "$ASSET_DIR/headline${idx}.txt")
        [ "$lines" -gt "$MAX_HEADLINE_LINES" ] && MAX_HEADLINE_LINES=$lines
    done
    echo "Longest headline wraps to $MAX_HEADLINE_LINES line(s)."

    HEADLINE_Y=300
    FACT_LABEL_Y=$((HEADLINE_Y + MAX_HEADLINE_LINES * HEADLINE_LINE_H + 45))
    FACT_TEXT_Y=$((FACT_LABEL_Y + 33))

    FACT_N=${#FACTS[@]}
    FACT_CYCLE=$((FACT_N * FACT_SLOT))
    for i in "${!FACTS[@]}"; do
        idx=$((i + 1))
        echo "${FACTS[$i]}" | fold -s -w 23 > "$ASSET_DIR/fact${idx}.txt"
    done

    #########################################
    # Filter chain: video + overlay + info text
    #########################################
    CHAIN="[0:v]scale=${OUT_W}:${OUT_H}:force_original_aspect_ratio=decrease,pad=${OUT_W}:${OUT_H}:(ow-iw)/2:(oh-ih)/2:black[video];"
    CHAIN+="[1:v]scale=${OUT_W}:${OUT_H}:flags=fast_bilinear[ovl];"
    CHAIN+="[ovl][video]overlay=0:0[base];"

    build_labels_chain "$url"
    CHAIN+="$LABELS_CHAIN"

    # Layout note: the video is assumed to have its own title (top-left, down
    # to y~110), a LIVE badge (top-right, down to y~65) and a credit line
    # (bottom-left, y~1045). So there is no LIVE badge here, the info block
    # starts below y=120, the credits/clock/stats sit top-right under the
    # video's LIVE badge, and the watermark is bottom-right.
    # Adjust the y values below if your black hole video has a different layout.

    # Credits / clock / stats (right-aligned, top-right, below the video's own LIVE badge)
    CHAIN+="${LABELS_OUT}drawtext=fontfile=${FONT}:text='Credit\: Video designed by Technical Talk India':fontcolor=white@0.9:fontsize=22:x=1870-text_w:y=90:${SHADOW}[p9];"
    CHAIN+="[p9]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/clock.txt:reload=1:fontcolor=${GOLD}:fontsize=21:x=1870-text_w:y=120:${SHADOW}[p10];"
    CHAIN+="[p10]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/subs.txt:reload=1:fontcolor=white@0.85:fontsize=19:x=1870-text_w:y=148:${SHADOW}[p10b];"
    CHAIN+="[p10b]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/viewers.txt:reload=1:fontcolor=white@0.85:fontsize=19:x=1870-text_w:y=174:${SHADOW}[p10c];"

    # Title (below the video's own title)
    CHAIN+="[p10c]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/title1.txt:fontcolor=white:fontsize=39:x=50:y=150:${SHADOW}[p11];"
    CHAIN+="[p11]drawbox=x=50:y=210:w=620:h=3:color=${GOLD}@0.8:t=fill[p13];"

    # Header + eyebrow
    CHAIN+="[p13]drawbox=x=50:y=234:w=12:h=12:color=${GOLD}:t=fill[p14];"
    CHAIN+="[p14]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/header.txt:fontcolor=${GOLD}:fontsize=22:x=74:y=230:${SHADOW}[p15];"
    CHAIN+="[p15]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/eyebrow.txt:fontcolor=${GOLD}@0.9:fontsize=18:x=50:y=270:${SHADOW}[p16];"

    # Rotating headlines
    local prev="p16"
    for i in "${!RAW_LINES[@]}"; do
        idx=$((i + 1))
        local start=$((i * SLOT))
        local end=$((start + SLOT))
        local nxt="h${idx}"
        local ALPHA="if(between(mod(t\,${CYCLE})\,${start}\,${end})\,if(lt(mod(t\,${CYCLE})-${start}\,0.6)\,(mod(t\,${CYCLE})-${start})/0.6\,if(gt(mod(t\,${CYCLE})-${start}\,${SLOT}-0.6)\,(${end}-mod(t\,${CYCLE}))/0.6\,1))\,0)"
        CHAIN+="[${prev}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/headline${idx}.txt:fontcolor=white:fontsize=${HEADLINE_FONTSIZE}:line_spacing=${HEADLINE_LINE_SPACING}:x=50:y=${HEADLINE_Y}:alpha='${ALPHA}':${SHADOW}[${nxt}];"
        prev="$nxt"
    done

    # Rotating "Did you know" facts
    CHAIN+="[${prev}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/fact_label.txt:fontcolor=${GOLD}@0.9:fontsize=18:x=50:y=${FACT_LABEL_Y}:${SHADOW}[fp2];"
    prev="fp2"
    for i in "${!FACTS[@]}"; do
        idx=$((i + 1))
        local start=$((i * FACT_SLOT))
        local end=$((start + FACT_SLOT))
        local nxt="f${idx}"
        local FALPHA="if(between(mod(t\,${FACT_CYCLE})\,${start}\,${end})\,if(lt(mod(t\,${FACT_CYCLE})-${start}\,0.6)\,(mod(t\,${FACT_CYCLE})-${start})/0.6\,if(gt(mod(t\,${FACT_CYCLE})-${start}\,${FACT_SLOT}-0.6)\,(${end}-mod(t\,${FACT_CYCLE}))/0.6\,1))\,0)"
        CHAIN+="[${prev}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/fact${idx}.txt:fontcolor=white@0.95:fontsize=24:line_spacing=10:x=50:y=${FACT_TEXT_Y}:alpha='${FALPHA}':${SHADOW}[${nxt}];"
        prev="$nxt"
    done

    BASE_CHAIN="$CHAIN"
    FACT_END="$prev"
}

#############################################
# build_final_filter: channel watermark and
# pulsing subscribe ring only (no CTA box,
# no bottom ticker, no frame).
#############################################
build_final_filter() {
    local tail="$BASE_CHAIN"

    tail+="[${FACT_END}]drawtext=fontfile=${FONT}:text='${CHANNEL_NAME}':fontcolor=white@0.55:fontsize=22:borderw=2:bordercolor=black@0.7:x=1810-text_w:y=1030[wm1];"

    local SUB_PULSE_ENABLE="lt(mod(t\,3)\,1)"
    local sub_ring_x=$((SUB_ICON_X - SUB_ICON_R))
    local sub_ring_y=$((SUB_ICON_Y - SUB_ICON_R))
    local sub_ring_d=$((SUB_ICON_R * 2))
    tail+="[wm1]drawbox=x=${sub_ring_x}:y=${sub_ring_y}:w=${sub_ring_d}:h=${sub_ring_d}:color=${GOLD}@0.9:t=4:enable='${SUB_PULSE_ENABLE}'[final]"

    echo "$tail"
}

#############################################
# Stream one video with automatic retry
#############################################
run_video() {
    local url="$1"
    local attempt=1

    prepare_video_content "$url"

    local filter
    filter=$(build_final_filter)

    while [ "$attempt" -le "$MAX_RETRIES" ]; do
        echo "----------------------------------------"
        echo "Streaming (attempt ${attempt}/${MAX_RETRIES}) @ ${OUT_W}x${OUT_H} ${OUT_FPS}fps:"
        echo "$url"
        echo "----------------------------------------"

        set +e
        ffmpeg \
        -hide_banner \
        -loglevel info \
        -reconnect 1 \
        -reconnect_streamed 1 \
        -reconnect_delay_max 5 \
        -re \
        -i "$url" \
        -loop 1 -i overlay.png \
        -loop 1 -i "$DOT_MARKER" \
        -filter_complex "$filter" \
        -map "[final]" \
        -map 0:a? \
        -r "$OUT_FPS" \
        -s "${OUT_W}x${OUT_H}" \
        -c:v libx264 \
        -preset "$X264_PRESET" \
        -tune zerolatency \
        -threads 2 \
        -profile:v high \
        -level 4.1 \
        -pix_fmt yuv420p \
        -b:v "$VIDEO_BITRATE" \
        -maxrate "$VIDEO_BITRATE" \
        -bufsize "$VIDEO_BUFSIZE" \
        -g $((OUT_FPS * 2)) \
        -keyint_min $((OUT_FPS * 2)) \
        -sc_threshold 0 \
        -c:a aac \
        -b:a 128k \
        -ar 48000 \
        -ac 2 \
        -shortest \
        -f flv \
        "rtmp://a.rtmp.youtube.com/live2/${YOUTUBE_STREAM_KEY}"
        local exit_code=$?
        set -e

        if [ "$exit_code" -eq 0 ]; then
            echo "Video finished normally."
            return 0
        fi

        echo "WARNING: ffmpeg exited with code ${exit_code} (attempt ${attempt}/${MAX_RETRIES})."
        attempt=$((attempt + 1))
        if [ "$attempt" -le "$MAX_RETRIES" ]; then
            echo "Retrying in ${RETRY_DELAY}s..."
            sleep "$RETRY_DELAY"
        else
            echo "ERROR: Max retries reached for this video. Moving on."
        fi
    done
    return 1
}

#############################################
# Stream loop
#############################################
IFS=',' read -ra RAW_URLS <<< "$VIDEO_URL"
URLS=()
for u in "${RAW_URLS[@]}"; do
    u="${u#"${u%%[![:space:]]*}"}"
    u="${u%"${u##*[![:space:]]}"}"
    [ -n "$u" ] && URLS+=("$u")
done
NUM_URLS=${#URLS[@]}
if [ "$NUM_URLS" -eq 0 ]; then
    echo "ERROR: VIDEO_URL contained no valid entries after parsing"
    exit 1
fi

if [ "$NUM_URLS" -gt 1 ]; then
    mapfile -t URLS < <(printf '%s\n' "${URLS[@]}" | shuf)
    echo "Shuffled playback order for this run:"
    for u in "${URLS[@]}"; do
        echo "  - $u"
    done
fi

while true; do
    for url in "${URLS[@]}"; do
        run_video "$url" || true
        echo ""
    done
done
