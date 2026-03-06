#include <metal_stdlib>
using namespace metal;

kernel void frameDeltaCompute(
    texture2d<float, access::read> current  [[texture(0)]],
    texture2d<float, access::read> previous [[texture(1)]],
    device atomic_uint* changedCount        [[buffer(0)]],
    constant float& threshold               [[buffer(1)]],
    uint2 gid                               [[thread_position_in_grid]])
{
    if (gid.x >= current.get_width() || gid.y >= current.get_height()) return;

    float4 curr = current.read(gid);
    float4 prev = previous.read(gid);

    // Sum of absolute differences across RGB channels
    float diff = abs(curr.r - prev.r) + abs(curr.g - prev.g) + abs(curr.b - prev.b);

    // Threshold: ~2/255 per channel summed = ~0.024
    if (diff > threshold) {
        atomic_fetch_add_explicit(changedCount, 1, memory_order_relaxed);
    }
}
