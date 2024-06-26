#ifndef __VORONOI_CGINC
#define __VORONOI_CGINC

#include "./Hash.cginc"

float2 voronoiCellPosition(float2 cell, float time) {
    return cell + abs(sin(rand2dTo2d(cell) * 2 + time));
}

// https://www.ronja-tutorials.com/post/028-voronoi-noise/
void voronoiNoise(float2 value, float density, float time, out float squaredDistToCenter, out float distToEdge, out float cellIdx)
{
    // TODO: check if two passes could be merged?

    value = value * density;
    
    float2 baseCell = floor(value);

    //first pass to find the closest cell
    squaredDistToCenter = 256;
    float2 closestCell;
    float2 toClosest = 0;
    [unroll]
    for (int x1 = -1; x1 <= 1; x1++)
    {
        [unroll]
        for (int y1 = -1; y1 <= 1; y1++)
        {
            float2 cell = baseCell + float2(x1, y1);
            float2 cellPosition = voronoiCellPosition(cell, time);
            float2 toCell = cellPosition - value;
            float distToCell = dot(toCell, toCell);
            if (distToCell < squaredDistToCenter)
            {
                squaredDistToCenter = distToCell;
                closestCell = cell;
                toClosest = toCell;
            }
        }
    }

    //second pass to find the distance to the closest edge
    distToEdge = 256;
    [unroll]
    for (int x2 = -1; x2 <= 1; x2++)
    {
        [unroll]
        for (int y2 = -1; y2 <= 1; y2++)
        {
            float2 cell = baseCell + float2(x2, y2);
            float2 cellPosition = voronoiCellPosition(cell, time);
            float2 toCell = cellPosition - value;

            float2 diffToClosestCell = abs(closestCell - cell);
            bool isClosestCell = diffToClosestCell.x + diffToClosestCell.y < 0.1;
            if (!isClosestCell)
            {
                float2 toCenter = (toClosest + toCell) * 0.5;
                float2 cellDifference = normalize(toCell - toClosest);
                float edgeDistance = dot(toCenter, cellDifference);
                distToEdge = min(distToEdge, edgeDistance);
            }
        }
    }

    cellIdx = rand2dTo1d(closestCell);
}

#endif