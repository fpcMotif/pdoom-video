kernel void layer_unpremultiply(texture2d<float, access::read> src [[texture(0)]],
                                 texture2d<float, access::write> dst [[texture(1)]],
                                 uint2 gid [[thread_position_in_grid]]) {
  uint2 size = uint2(src.get_width(), src.get_height());
  if (gid.x >= size.x || gid.y >= size.y) return;
  float4 c = src.read(gid);
  float3 straight = c.a > 1e-5 ? toLinear(min(c.rgb / c.a, 1.0)) : float3(0.0);
  uint2 dstGid = uint2(gid.x, size.y - 1 - gid.y);
  dst.write(float4(straight, c.a), dstGid);
}
