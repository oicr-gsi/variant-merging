#!/usr/bin/perl -w

use strict;
use constant DEBUG=>0;
use Getopt::Long;
use Data::Dumper;

=head2 postprocess_vcf.pl

 TODO: postprocessing should optionally collapse the vcf into 2-column 
 (having NORMAL and TUMOR columns) vcf. The rules are simple: there should be no 
 collision of fields, we just need to to take first two data columns (NORMAL) and
 merge the values + take the last two columns (TUMOR) and merge those too.
 collapse will be set by default outside this script

=cut

my($bgzip,$input,$tabix,$collapse,$passonly);
my $result = GetOptions ('input=s'    => \$input,    # input vcf file
                         'collapse'   => \$collapse, # collapse 4-column vcf into 2-column vcf
                         'pass-only'  => \$passonly, # output only PASS calls
                         'bgzip=s'    => \$bgzip,    # directory with temporary GATK files
                         'tabix=s'    => \$tabix);   # file with calculated indexes

my $USAGE = "postprocess_vcf.pl --input [vcf file] --bgzip [path to bgzip] --tabix [path to tabix] --collapse [flag to indicate the merge of 4 columns into 2] --pass-only [optional flag to filter passed calls]\n";

if (! -e $input || ! -e $bgzip || ! -e $tabix) { die $USAGE; }

my $file = &collapse($input);

`$bgzip -c $file > $input.gz && $tabix -p vcf $input.gz`;
print STDERR "Finished preparing vcf file\n";

=head2 collapse

 Optionally collapse last four columns into two
 and fix the header (make it NORMAL TUMOR)

 Here we also check if we were asked 
 to keep only PASS calls

=cut

sub collapse {

my $in = shift @_;
open(VCF, "<$in") or die "Couldn't read from [$in]";
my $tmp = $in; 
$tmp.="_$$";
print STDERR "Opening [$tmp]\n";

open(TMP,">$tmp") or die "Couldn't write to temporary file [$tmp]";

while(<VCF>) {
 if(/^##/){ ### the headers #########################
    if (/ID=(PASS)/ || /ID=(REJECT)/) {
      my $call = $1;
      print STDERR "Detected $call field\n" if DEBUG;
      my $description = $call eq "PASS" ? "Note that PASS marks variants approved by at least One of two callers" 
                                        : "Note that REJECT marks variants failed by Both of two callers";
      if (/Description/) {
          s/(Description=\".*?)\"/$1;$description\"/;
      } else { ### add description key
          if ($_=~/\>/) {
              s/\>/,Description=\"$description\">/;
          } 
      }
    }
    print TMP $_;
 } elsif (/^#/){ ### the column headerline ###############
    my $colheader = $_;
    chomp($colheader);
    $colheader =~s/FORMAT.*/FORMAT/;
    $colheader = join("\t",($colheader, "NORMAL","TUMOR"));
    print TMP $colheader."\n";
 } else {        ### the data records ####################
   # Join the column's data here
   chomp;
   my @f=split /\t/;
 
   if ($f[6] ne 'PASS' && $passonly) {
     print STDERR "Filtering REJECT calls\n" if DEBUG;
     next;
   }

   if (!$collapse) {
     print TMP $_."\n";
     next;
   }

   if (scalar(@f) != 13) {
     print STDERR "The line has less than 13 columns, no merging\n";
     print join("\t",@f)."\n";
     next;
   }

   ### Disambiguate last four columns
   my @cols = grep {/:/} @f[9..12];
   if (scalar(@cols) == 2) {
     print TMP join("\t",(@f[0..8],@cols))."\n";
     next;
   } 

   ### Here we need to merge
   my $fields = {normal => {one => [split(":",$cols[0])],
                            two => [split(":",$cols[1])]},
                 tumor  => {one => [split(":",$cols[2])],
                            two => [split(":",$cols[3])]}};
   my($normal,$tumor);
   my($first,$second) = scalar(@{$fields->{normal}->{one}}) >= scalar(@{$fields->{normal}->{two}}) ? ('one','two') : ('two','one');
   
   foreach my $subset('normal','tumor') {
     for (my $i = 0; $i < scalar(@{$fields->{$subset}->{$first}}); $i++) {
      if ($fields->{$subset}->{$first}->[$i] !~/\d/ && $fields->{$subset}->{$second}->[$i]) { 
          $fields->{$subset}->{$first}->[$i] = $fields->{$subset}->{$second}->[$i]; 
      }
    }
    my $merged = join(":",@{$fields->{$subset}->{$first}});
    $subset eq 'normal' ? $normal = $merged : $tumor = $merged;
   }

   print TMP join("\t",(@f[0..8],($normal,$tumor)))."\n";
 }
}

close VCF;
close TMP;

return $tmp;
}