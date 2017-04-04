#!/bin/bash

#convert TimeKeeper32x32.png -colors 16 TimeKeeper32x32.xpm
convert TimeKeeper16x16.png -colors 16 TimeKeeper16x16.xpm
convert TimeKeeper16x16.png -resize 32x32 -colors 16 TimeKeeper32x32.xpm

