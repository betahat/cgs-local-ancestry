#!/usr/bin/perl -w -I .
use strict;
use cmdline_args;

if (!$ARGV[0] || $ARGV[0] eq "help") {
  print STDERR <<EOF;

  Script to execute combined phasing (optional) and rfmix v2.X local ancestry
  analysis on any supplied VCF/BCF file.

  Usage: --vcf <input VCF/BCF file> [ --no-phasing ] [ --assume-reference ]   

  Performs phasing and local ancestry analysis using 1000 genomes phase 3
  genotypes as reference (built in), reduced to bi-allelic SNPs only which
  have a minimum minor allele count of 20.

  --no-phasing: input VCF/BCF is already phased, do not phase input prior to
                local ancestry analysis

  --assume-reference: for any SNP in reference data for which no record is
                      in the input VCF/BCF, substitute the homozygous reference
                      allele for all samples in input. NOTE: If missing data
		      (./. or .|.) is explicitly given in the input, reference
		      alleles will not be substituted. Explict missing data is ok.

		      IMPORTANT: use this option only with high-coverage WGS data
		      
		      If this option is not specified, only SNPs found in the
		      intersection of the input and the reference data will be used.

   For local ancestry analysis:
   Built-in reference panel groups the 1KG data into 5 reference populations: European,
   East Asian, African, South Asian, and Native American, selecting only samples which
   appear to be of almost pure ancestry in these groups. All other 1KG samples are
   excluded.

   For phasing:
   Entire 1KG panel of samples is used a reference haplotypes

   Phasing is performed by Eagle v2.3 author Po-Ru Loh, (C) 2015-2016 Harvard University
   distributed under the GNU GPL v3 open source license

   local ancestry analysis is performed by RFMIX v2.X author Mark Koni Wright,
   (C) 2015-2016 Mark Wright, Stanford University.
   
EOF
  exit -1
}

my ($vcf_fname, $no_phasing, $assume_reference) = ("", 0, 0);
my %args;
$args{'--vcf'} = [ \$vcf_fname,          1 ];
$args{'--no-phasing'} = [ \$no_phasing,  0 ];
$args{'--assume-reference'} = [ \$assume_reference, 0 ];
cmdline_args::get_options(\%args, \@ARGV);

$ENV{PATH} = "$ENV{ANCESTRY_ROOT}/bin:$ENV{PATH}";
$ENV{BCFTOOLS_PLUGINS} = "$ENV{ANCESTRY_ROOT}/bin/bcftools_plugins";
  
if ($vcf_fname eq "") {
  system($0);
  print STDERR "ERROR: Specify VCF or BCF input file with --vcf <filename> option\n\n";
  exit(-1);
}
my $output_basename = $vcf_fname;
$output_basename =~ s/\.[vb]cf(\.gz|\.bgz|\.bz2|)$//;
my $tmp_dname = "tmp.$$";
echo_exec("mkdir -p $tmp_dname");
echo_exec("rm -f $output_basename.rfmix.msp.tsv");
echo_exec("rm -f $output_basename.rfmix.fb.tsv");
echo_exec("rm -f $output_basename.rfmix.Q");

if (! open(F, "<$vcf_fname") ) {
  print STDERR "Can't open input VCF/BCF file \"$vcf_fname\" ($!)";
  exit -1;
}
close F;

if ($assume_reference) {
  if (echo_exec("/usr/bin/time --format='%e sec\\t%E\\t%M KB' insert-reference-homozygote.py $vcf_fname $ENV{RFMIX_REFERENCE} | bcftools view --output-type b > $tmp_dname/tmp.filled.bcf.gz")) {
    print STDERR "\nFailed to insert homozygous reference genotypes at ancestry reference sites.\n\n";
    exit -1;
  }
  $vcf_fname = "$tmp_dname/tmp.filled.bcf.gz";
}

for(my $chm=1; $chm <= 22; $chm++) {
  echo_exec("bcftools index $vcf_fname");

  my $current_vcf_fname = "$tmp_dname/tmp.$chm.bcf.gz";
  echo_exec("bcftools view --output-type b --regions $chm $vcf_fname > $current_vcf_fname");
  echo_exec("bcftools index $current_vcf_fname");
  unless ($no_phasing) {
    if (echo_exec("eagle --geneticMapFile $ENV{ANCESTRY_ROOT}/phasing-reference/genetic_map_hg19_withX.txt.gz --numThreads 24 --vcfRef $ENV{ANCESTRY_ROOT}/phasing-reference/1KG.20ac.all.bcf.gz --vcfTarget $current_vcf_fname --vcfOutFormat b --outPrefix $tmp_dname/tmp.phased.$chm --chrom $chm --noImpMissing")) {
      print STDERR "\nWARNING: Failed to phase chromosome $chm - skipping ancestry analysis for this chromosome.\n";
      next;
    }
    $current_vcf_fname = "$tmp_dname/tmp.phased.$chm.bcf";
    echo_exec("bcftools index $current_vcf_fname");      
  }

  if (echo_exec("rfmix -f $current_vcf_fname -r $ENV{RFMIX_REFERENCE} -m $ENV{RFMIX_REFERENCE_MAP} -g $ENV{ANCESTRY_ROOT}/rfmix-reference/hapmap-phase2-genetic-map.tsv -o $tmp_dname/tmp.rfmix.$chm --chromosome=$chm --crf-spacing=0.1 --rf-window-size=0.1 -G 8 -t 100 --max-missing=0.1 --rf-minimum-snps=20 --random-seed=0xDEADBEEF --crf-weight=3")) {
    print STDERR "\nWARNING: RFMIX analysis failed on chromosome $chm\n\n";
    next;
  }
  echo_exec("cat $tmp_dname/tmp.rfmix.$chm.msp.tsv >> $output_basename.rfmix.msp.tsv");
  echo_exec("cat $tmp_dname/tmp.rfmix.$chm.fb.tsv >> $output_basename.rfmix.fb.tsv");
  echo_exec("cat $tmp_dname/tmp.rfmix.$chm.rfmix.Q >> $output_basename.rfmix.Q");
}

sub echo_exec {
  my @args = @_;

  print join(" ",@args),"\n";
  return system(@args);
}