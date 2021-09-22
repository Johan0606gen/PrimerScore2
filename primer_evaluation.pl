#!/usr/bin/perl -w
use strict;
use warnings;
use Getopt::Long;
use Data::Dumper;
use FindBin qw($Bin $Script);
use File::Basename qw(basename dirname);
require "$Bin/common.pm";
require "$Bin/product.pm";
require "$Bin/path.pm";

my $BEGIN_TIME=time();
my $version="1.0.0";
#######################################################################################

# ------------------------------------------------------------------
# GetOptions
# ------------------------------------------------------------------
my ($foligo,$fbound,$fprobe,$fkey,$outdir);
our $REF_HG19;
my $fdatabases = $REF_HG19;
my $ptype = "face-to-face";
my $PCRsize=1000;
my $min_eff=0.01;
my $opt_tm = 60;
my $opt_tm_probe = 70;
my $max_prodn=50;
my $range;
my $thread = 3;
my $etype="SinglePlex";
my ($AllEvalue, $OutAllProduct);
GetOptions(
				"help|?" =>\&USAGE,
				"io:s"=>\$foligo,
				"ib:s"=>\$fbound,
				"id:s"=>\$fdatabases,
				"k:s"=>\$fkey,
				"tp:s"=>\$ptype,
				"ep:s"=>\$etype,
				"AllEvalue:s"=>\$AllEvalue,
				"OutAllProduct:s"=>\$OutAllProduct,
				"rd:s"=>\$range,
				"tm:s"=>\$opt_tm,
				"tmb:s"=>\$opt_tm_probe,
				"sz:s"=>\$PCRsize,
				"mp:s"=>\$max_prodn,
				"me:s"=>\$min_eff,
				"td:s"=>\$thread,
				"od:s"=>\$outdir,
				) or &USAGE;
&USAGE unless ($foligo and $fkey);
$outdir||="./";
`mkdir $outdir`	unless (-d $outdir);
$outdir=AbsolutePath("dir",$outdir);

if($ptype eq "face-to-face"){
	$range=defined $range? $range:"70,200";
}elsif($ptype eq "Nested"){
	$range=defined $range? $range:"5,30";
}elsif($ptype eq "back-to-back"){
	$range=defined $range? $range:"0,15";
}else{
	die "Wrong primer type! Must be face-to-face, back-to-back or Nested!\n";
}
my ($mind, $maxd)=split /,/, $range;


my $fevalue;
my $ftype;
my $info = `tail -1 $foligo`;
chomp $info;
my $col = scalar(split /\s+/, $info);
my $idx;
if($col ==2){
	$ftype="Common";
	$idx = 0;
}elsif($col==23){
	$ftype="Evalue";
	$idx = 3;
	$fevalue = $foligo;
}

if(!defined $fbound){
	### evalue single oligo
	if($ftype ne "Common"){
		die "Wrong file type: must be Common(2column: id seq) when not defined -ib!\n";
	}
	&Run("perl $Bin/oligo_evaluation.pl --nohead -p $foligo -d $fdatabases -thread $thread -stm 45 --NoFilter -k $fkey -od $outdir");
	$fevalue = "$outdir/$fkey.evaluation.out";
	$fbound = "$outdir/$fkey.bound.info";
}else{
	if($ftype ne "Evalue"){
		die "Wrong file type: must be Evalue type(24column) when defined -ib!\n";
	}
}

my %id;
open(I, $foligo) or die $!;
while(<I>){
	chomp;
	next if(/^$/ || /^#/);
	my @unit=split /\s+/, $_;
	my $id=$unit[$idx];
	my ($tid, $type)=$id=~/(\S+)-([12LRP])/;
	$id{$id}=0;
}
close(I);

### evalue combination oligos
my %bound;
my %boundm;
&SHOW_TIME("#Read in Bound file");
open(B, $fbound) or die $!;
while(<B>){
	chomp;
	my ($id, $strand, $chr, $pos3, $seq, $tm, $end_match, $mvisual)=split /\t/, $_;
	next if(!exists $id{$id});
	$id{$id}=1;
	my ($tid, $type)=$id=~/(\S+)-([12LRP])/;
	if(!defined $tid || !defined $type){
		die "Wrong oligo ID $id: Primer ID must end by -L/R/1/2, eg. xxx-L, xxx-R, xxx-1, xxx-2; Probe ID must end by -P, eg. xxx-P!\n";
	}
	my $len = length $seq;
	my $pos5=$strand eq "+"? $pos3-$len+1: $pos3+$len-1;
	push @{$bound{$type}{$tid}{$chr}{$strand}}, [$pos3, $pos5, $tm, $end_match, $mvisual, $tid];
}
close(B);
foreach my $id(keys %id){
	if($id{$id}==0){
		print "Warn: $id not exist bound info and cannot evalue its products!\n";
	}
}

my %product;
my %record;
my @tps = sort {$a cmp $b} keys %bound;
&SHOW_TIME("#Evalue");
foreach my $tp1(@tps){
	next if($tp1 eq "P"); 
	## AllEvalue: L<->R L<->L R<->R
	next if($etype eq "SinglePlex" && !defined $AllEvalue && $tp1 ne $tps[0]); ## only evalue one type 
	foreach my $tid1 (sort {$a cmp $b} keys %{$bound{$tp1}}){
		foreach my $tp2(@tps){
			next if($tp2 eq "P");
			next if(!defined $AllEvalue && $tp2 eq $tp1); ## Only evalue product between pairs with different types, L<-->R; 1<-->2
			foreach my $tid2(keys %{$bound{$tp2}}){
				next if($etype eq "SinglePlex" && $tid2 ne $tid1); ## SinglePlex: not evalue product between different tid
				next if(exists $record{"pro"}{$tid2."-".$tp2}{$tid1."-".$tp1});
				&caculate_product($tid1, $tid1."-".$tp1, $tid2, $tid2."-".$tp2, $bound{$tp1}{$tid1}, $bound{$tp2}{$tid2}, $ptype,\%product, \%record, $PCRsize, $opt_tm, $mind, $maxd, $min_eff, $max_prodn);
				$record{"pro"}{$tid1."-".$tp1}{$tid2."-".$tp2}=1;
			}
		}
	}
}

my %productp;
if(exists $bound{"P"}){#Probe
	foreach my $tid(keys %{$bound{"P"}}){
		# probe num on products
		&probe_bounds_on_products($tid."-P", $bound{"P"}{$tid}, $product{$tid}{$tid}, \%productp, $PCRsize, $opt_tm_probe); #my ($id, $abound, $aprod, $aresult)=@_;
	}
}

### output
open(I, $fevalue) or die $!;
open(O, ">$outdir/$fkey.final.evaluation") or die $!;
print O "#ID\tSeq\tLen\tTm\tGC\tHairpin\tEND_Dimer\tANY_Dimer\tEndANum\tEndStability\tSNP\tPoly\tOligoBound\tBoundNum\tHighestTm\tHighestInfo\n";
if(defined $OutAllProduct){
	open(P, ">$outdir/$fkey.final.pair.product") or die $!;
}
while(<I>){
	chomp;
	next if(/^$/ || /^#/);
	my (@info)=split /\t/, $_;
	my $id=$info[$idx];
	my $sbinfo=pop @info;
	my $sbeff=pop @info;
	my $sbnum=pop @info;
	my $sbd = $sbnum."|".$sbeff;
	my ($tid,$tp)=$id=~/(\S+)-([12LRP])$/;
	my ($pnum, $apeff, $apinfos);
	if($tp ne "P"){
		($pnum, $apeff, $apinfos)=&get_highest_bound($product{$tid}{$tid}, 1000000);
	}else{
		($pnum, $apeff, $apinfos)=&get_highest_bound($productp{$id}, 1000000);
	}
	my ($peffs, $pinfos);
	if($pnum!~/\+/ && $pnum<=3){
		$peffs = join(",", @{$apeff});
		$pinfos = join(";", @{$apinfos});
	}else{
		$peffs = join(",", @{$apeff}[0..2]);
		$pinfos = join(";", @{$apinfos}[0..2]);
	}
	print O join("\t", $id, @info, $sbd, $pnum, $peffs, $pinfos),"\n";
	if(defined $OutAllProduct){
		if($tp!~/[2R]/){
			print P ">$id\t$pnum\n";
			my @peff=@{$apeff};
			my @pinfo=@{$apinfos};
			for(my $i=0; $i<@{$apeff}; $i++){
				print P join("\t", $apinfos->[$i], $apeff->[$i]),"\n";
			}
		}
	}
}
close(I);
close(O);
if(defined $OutAllProduct){
	close(P);
}

if($etype eq "MultiPlex"){
	open(C, ">$outdir/$fkey.final.cross.product") or die $!;
	foreach my $tid1(keys %product){
		foreach my $tid2(keys %{$product{$tid1}}){
			next if($tid1 eq $tid2);
			
			my ($pnum, $apeff, $apinfos)=&get_highest_bound($product{$tid1}{$tid2}, 1000000);
			print C ">$tid1\t$tid2\t$pnum\n";
			my @peff=@{$apeff};
			my @pinfo=@{$apinfos};
			for(my $i=0; $i<@{$apeff}; $i++){
				print C join("\t", $apinfos->[$i], $apeff->[$i]),"\n";
			}
		}
	}
	close(C);
}
#######################################################################################
print STDOUT "\nDone. Total elapsed time : ",time()-$BEGIN_TIME,"s\n";
#######################################################################################

# ------------------------------------------------------------------
# sub function
# ------------------------------------------------------------------

sub USAGE {#
	my $usage=<<"USAGE";
Program:
Version: $version
Contact:zeng huaping<huaping.zeng\@genetalks.com> 

	-io: oligo file can be two format as following, ID must like: xxx-L, xxx-R, xxx-P, xxx-1, xxx-2.
		Common Format:
		ID1-1   AAAAAAAAAAAA
		ID1-P   AAAAAAAAAAAAAAAA
		ID1-2   AAAAAAAAAAAA
		ID2-1   AAAAAAAAAAAA
		ID2-P   AAAAAAAAAAAAAAAA
		ID2-2   AAAAAAAAAAAA

		Evalue Format: xxx.final.result
		#Chr    Start   Strand  ID      Seq     Len     Dis2Target      ProductSize     ScoreTotal      ScorePair       ScoreOligo      Tm      GC      Hairpin END_Dimer       ANY_Dimer       EndANum EndStability    SNP     Poly    OligoBound      BoundNum        HighestTm       HighestInfo
		chr1    100379124       -       rs113994132-B1-1        TTTTTCTGTTCCACTCATCATATGAGA     27      0       162     286     25,11,10,20,30  41|3,10,0,7,10,-5,5,0   58.90   0.333   55.89   7.91    20.73   1       -6.7    0D1:TTTTTCTGTTCCACTCATCATATGAGE 22T5    10|58.84,49.32,48.69    1       1.00    162/chr1,P1,-100379124,|||||||||||||||||||||||||||,58.84,P2,+100378962,|||||||||||||||||||||||||||||,59.58
		chr1    100379097       -       rs113994132-B1-P        CCTTTATAGCCTTTCCTGAAAAATGACATAAGACATGGTA        40      40      0       286     30      63.5|1,3,10,5,10,10,3,7 66.39   0.350   30.67   -18.20  -6.10   2       0       NA      17A5,26T3,35T3  15|65.97,50.26,49.55    1       0.86    27/chr1,-100379097,||||||||||||||||||||||||||||||||||||||||,65.97:chr1,P1,-100379124,|||||||||||||||||||||||||||,58.84,P2,+100378962,|||||||||||||||||||||||||||||,59.58


	-rd: distance range between primer pair(P2-P1)

      face-to-face: |---> P1             distance range: 70,200
                          P2 <---|  

      back-to-back:  x <---| P2          distance range(>0): 0,15 
                      P1 |---> x           

      back-to-back:  x <---| P2         distance range(<0): -40,-10
                           P1 |---> x          

            Nested: P1 --->|   x        distance range: 5,30
                      P2 --->| x                

            Nested: P2 --->|   x        distance range: -30,-5
                      P1 --->| x                

Usage:
  Options:
  -io        <file>   Input oligo file, Common or Evalue format(as shown in the above), forced
                      when -ib is  given, must be Evalue format.
                      when -ib not given, must be Common format.
  -ib        <file>   Input oligo's bounds file, evalue oligos when not given, optional
  -id        <files>  Input database files separated by "," to evalue specificity, [$fdatabases]
  -k         <str>    Key of output file, forced
  -tp        <str>    primer type, "face-to-face", "back-to-back", "Nested", ["face-to-face"]
  -ep        <str>    evalue type, "SinglePlex", "MultiPlex", ["SinglePlex"]
  -mp        <int>    maximum products number to be caculated, to reduce running time. [$max_prodn]
  --AllEvalue         All Evalue, not only L<->R, contain L<->L and R<->R.
  --OutAllProduct    Output All Product Info.
  -td        <int>    thread in bwa, [$thread]
  -od        <dir>	  Dir of output file, default ./

  Caculating efficiency options:
  -sz        <int>    max PCR fragment size, [$PCRsize]
  -tm        <int>    optimal tm of primer, [$opt_tm]
  -tmb       <int>    optimal tm of probe, [$opt_tm_probe]
  -rd      <int,int>  distance range between primer pair, optional
                      default:
                      when -tp is "face-to-face", [70,200]
                                  "back-to-back", [0,15]
                                  "Nested",       [5,30]
  -me       <float>   min efficiency to consider a product, [$min_eff]

  -h		   Help

USAGE
	print $usage;
	exit;
}

