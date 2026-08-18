return { body = [[
A diagnostic for the touch panel. The whole screen is one press area, and each press leaves three markers so you can see exactly what the panel reported.

- blue - follows your finger for as long as it is down
- red - the touchdown point, the coordinate the UI uses to decide which button a tap hits
- green - where the contact was when you lifted

On a clean tap red and green land on top of each other. A gap between them means the contact moved, or the reading moved under a still finger.

The readout shows both pairs of coordinates, and next to each the panel's own raw numbers from before they are mapped to the screen. The last line carries the excursion during the press, the biggest single jump, how many samples it took, and the most simultaneous contacts seen.

Nothing is written to the serial log - everything is on screen.

WHAT IT IS FOR
Checking whether taps land where you touch, especially at the edges and corners, and whether two-finger input registers. If the markers sit away from your finger, or a tap needs several tries near an edge, this is the app that shows it in numbers rather than by feel.]] }
