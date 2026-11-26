# build an openofdm_tx BRAM image exactly like wifi_pkg::wifi_frame::bram_words (tx_bit_intf.v layout)
import os, sys, random, importlib.util
spec=importlib.util.spec_from_file_location("ref",os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "scripts", "wifi_ref_tx.py")); ref=importlib.util.module_from_spec(spec); spec.loader.exec_module(ref)
ht=int(sys.argv[1]); rate=int(sys.argv[2]); sgi=int(sys.argv[3]); n=int(sys.argv[4]); out=sys.argv[5]
random.seed(n*31+rate); mpdu=[random.randrange(256) for _ in range(n)]
L=n+4
if ht:
    nbpsc,cr=ref.HT[rate]; ndbps=nbpsc*52*cr[0]//cr[1]; nsym=-(-(16+8*L+6)//ndbps)
    nl=-(-(72*nsym)//80) if sgi else nsym; ll=3*(4+nl)-3; rc=11
else:
    ll=L; rc=ref.LEG_CODE[rate]
lsd=(ll<<5)|rc; par=bin(lsd).count('1')&1
w=[(ht<<24)|(par<<17)|lsd]
if ht:
    hsd=(sgi<<31)|(0b111<<24)|(L<<8)|rate
    crc=ref.ht_sig_crc([(hsd>>i)&1 for i in range(34)]); c=sum(b<<i for i,b in enumerate(crc))
    w.append((c<<34)|hsd)
else:
    w.append(0)
for i in range(0,n,8):
    w.append(sum(mpdu[i+k]<<(8*k) for k in range(8) if i+k<n))
open(out,'w').write('\n'.join('%016X'%x for x in w)+'\n')
