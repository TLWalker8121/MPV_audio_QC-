# MPV_audio_QC-
Small lua script to add to portable config for mpv to allow visual monitoring of audio channels and isolation of audio channels within MPV. This utilises libavfilter package components: astats for audio monitoring statistics and pan for channel isolation. This script has been tested for implementation with shinchiro mpv build. 

To toggle overlay = Ctrl+shift+A 
To isolate channels = Ctrl+[channel number] 
To clear isolation = Ctrl+0


Display Variables: 

SILENT = channel is reading at less than -80db.  Line 21  
Bar resolution = 8 blocks. Line 22
Bar full = 0db. Line 24
Bar Empty = -60db. Line 23
Refresh rate = 0.15s. Line 20




Implementation:

Once mpv compiled, create portable_config directory inside the main application directory. Create 'scripts' directory inside. Add .lua to this directory. Test script added to repo for checking diretory config. 
