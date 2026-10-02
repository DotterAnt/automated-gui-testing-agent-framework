using System;
using System.Runtime.InteropServices;

// Read-only scan of decoded pixels. No drawing, image saving or app APIs.
public static class AGTAImagePixels {
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
