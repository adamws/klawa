layout_file := "./tools/keyboard-layout.json"

genkeyboard:
  . ./tools/.env/bin/activate
  python tools/genkeyboard.py -in {{layout_file}}
