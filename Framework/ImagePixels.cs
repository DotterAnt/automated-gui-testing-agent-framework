using System;
using System.Runtime.InteropServices;

// Read-only scan of decoded pixels. No drawing, image saving or app APIs.
public static class AGTAImagePixels {
    public sealed class Comparison {
        public double meanError, maxTileError;
    }
    public static Comparison Compare(IntPtr actual,int actualStride,IntPtr reference,int referenceStride,int size) {
        if (size<64 || size>512 || size%8!=0) throw new ArgumentException("Comparison size must be 64..512 and divisible by eight.");
        var a=new byte[checked(size*4)]; var b=new byte[a.Length];
        var tiles=new double[64]; double sum=0;
        for (int y=0;y<size;y++) {
            Marshal.Copy(IntPtr.Add(actual,checked(y*actualStride)),a,0,a.Length);
            Marshal.Copy(IntPtr.Add(reference,checked(y*referenceStride)),b,0,b.Length);
            for (int x=0;x<size;x++) {
                double delta=0;
                for (int channel=0;channel<3;channel++) delta+=Math.Abs(a[x*4+channel]-b[x*4+channel]);
                delta/=3; sum+=delta; tiles[(y*8/size)*8+x*8/size]+=delta;
            }
        }
        double max=0;
        foreach (double tile in tiles) max=Math.Max(max,tile/(size*size/64));
        return new Comparison {meanError=sum/(size*size),maxTileError=max};
    }
    public static long[] Count(IntPtr scan,int stride,int width,int height,int[] ranges) {
        if (ranges.Length%7!=0) throw new ArgumentException("Color ranges need seven bounds each.");
        var counts=new long[ranges.Length/7];
        var row=new byte[checked(width*4)];
        for (int y=0;y<height;y++) {
            Marshal.Copy(IntPtr.Add(scan,checked(y*stride)),row,0,row.Length);
            for (int x=0;x<row.Length;x+=4) {
                int b=row[x],g=row[x+1],r=row[x+2],a=row[x+3];
                for (int color=0;color<counts.Length;color++) {
                    int k=color*7;
                    if (r>=ranges[k] && r<=ranges[k+1] && g>=ranges[k+2] && g<=ranges[k+3] &&
                        b>=ranges[k+4] && b<=ranges[k+5] && a>=ranges[k+6]) counts[color]++;
                }
            }
        }
        return counts;
    }
}
