#!/bin/bash

update() {
  WIDTH="dynamic"
  if [ "$SELECTED" = "true" ]; then
    WIDTH="0"
  fi

  sketchybar --animate tanh 20 --set $NAME icon.highlight=$SELECTED label.width=$WIDTH
}

# DEVIATION from e6288b3: keyboard switches announce their destination through
# the space_eager event before macOS commits the switch animation; highlight
# immediately, query-free. space_change later settles authoritative state.
eager() {
  SELECTED="false"
  if [ "$SID" = "$TARGET" ]; then
    SELECTED="true"
  fi
  sketchybar --set $NAME icon.highlight=$SELECTED
}

mouse_clicked() {
  if [ "$BUTTON" = "right" ]; then
    yabai -m space --destroy $SID
    sketchybar --trigger space_change --trigger windows_on_spaces
  else
    yabai -m space --focus $SID 2>/dev/null
  fi
}

case "$SENDER" in
  "mouse.clicked")
    mouse_clicked
    ;;
  "space_eager")
    eager
    ;;
  *)
    update
    ;;
esac
