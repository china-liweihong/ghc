/* -----------------------------------------------------------------------------
 * $Id: Stats.c,v 1.14 1999/09/15 13:45:20 simonmar Exp $
 *
 * (c) The GHC Team, 1998-1999
 *
 * Statistics and timing-related functions.
 *
 * ---------------------------------------------------------------------------*/

#define NON_POSIX_SOURCE

#include "Rts.h"
#include "RtsFlags.h"
#include "RtsUtils.h"
#include "StoragePriv.h"
#include "MBlock.h"

/**
 *  Ian: For the moment we just want to ignore
 * these on Nemesis
 **/
#ifdef _NEMESIS_OS_
#ifdef HAVE_SYS_TIMES_H
#undef HAVE_SYS_TIMES_H /* <sys/times.h> */
#endif
#ifdef HAVE_SYS_RESOURCE_H /* <sys/resource.h> */
#undef HAVE_SYS_RESOURCE_H
#endif
#ifdef HAVE_SYS_TIME_H  /* <sys/time.h> */
#undef HAVE_SYS_TIME_H
#endif
#ifdef HAVE_SYS_TIMEB_H 
#undef HAVE_SYS_TIMEB_H /* <sys/timeb.h> */
#endif
#ifdef HAVE_UNISTD_H
#undef HAVE_UNISTD_H    /* <unistd.h> */
#endif
#ifdef HAVE_TIMES
#undef HAVE_TIMES
#endif 
#ifdef HAVE_FTIME
#undef HAVE_FTIME
#endif
#ifdef HAVE_GETRUSAGE
#undef HAVE_GETRUSAGE
#endif
#ifdef HAVE_SYSCONF
#undef HAVE_SYSCONF
#endif
#endif /* _NEMESIS_OS_ */

#include "Stats.h"

#ifdef HAVE_UNISTD_H
#include <unistd.h>
#endif

#ifndef __MINGW32__
# ifdef HAVE_SYS_TIMES_H
#  include <sys/times.h>
# endif
#endif

#ifdef HAVE_SYS_TIME_H
#include <sys/time.h>
#endif

#ifdef __CYGWIN32__
# ifdef HAVE_TIME_H
#  include <time.h>
# endif
#endif

#if ! irix_TARGET_OS && ! defined(__MINGW32__)
# if defined(HAVE_SYS_RESOURCE_H)
#  include <sys/resource.h>
# endif
#endif

#ifdef HAVE_SYS_TIMEB_H
#include <sys/timeb.h>
#endif

#if HAVE_STDLIB_H
#include <stdlib.h>
#endif

#if HAVE_WINDOWS_H
#include <windows.h>
#endif

/* huh? */
#define BIG_STRING_LEN              512

static double ElapsedTimeStart = 0.0;
static double TicksPerSecond   = 0.0;

static double InitUserTime = 0.0;
static double InitElapsedTime = 0.0;

static ullong GC_tot_alloc = 0;
static ullong GC_tot_copied = 0;

static double GC_start_time,  GC_tot_time = 0;  /* User GC Time */
static double GCe_start_time, GCe_tot_time = 0; /* Elapsed GC time */

lnat MaxResidency = 0;     /* in words; for stats only */
lnat ResidencySamples = 0; /* for stats only */

static lnat GC_start_faults = 0, GC_end_faults = 0;

static double *GC_coll_times;

/* ToDo: convert this to use integers? --SDM */

/* elapsedtime() -- The current elapsed time in seconds */

#ifdef _WIN32
#define NS_PER_SEC 10000000LL
/* Convert FILETIMEs into secs since the Epoch (Jan1-1970) */
#define FT2longlong(ll,ft)    \
    (ll)=(ft).dwHighDateTime; \
    (ll) <<= 32;              \
    (ll) |= (ft).dwLowDateTime; \
    (ll) /= (unsigned long long) (NS_PER_SEC / CLOCKS_PER_SEC)
#endif

#ifdef _WIN32
/* cygwin32 or mingw32 version */
double
elapsedtime(void)
{
    FILETIME creationTime, exitTime, kernelTime, userTime;
    long long int kT, uT;
 
 
    /* ToDo: pin down elapsed times to just the OS thread(s) that
       are evaluating/managing Haskell code.
    */
    if (!GetProcessTimes (GetCurrentProcess(), &creationTime,
		          &exitTime, &kernelTime, &userTime)) {
	/* Probably on a Win95 box..*/
	return 0;
    }

    FT2longlong(kT,kernelTime);
    FT2longlong(uT,userTime);
    return (((StgDouble)(uT + kT))/TicksPerSecond - ElapsedTimeStart);
}

#else 

double
elapsedtime(void)
{
# if ! (defined(HAVE_TIMES) || defined(HAVE_FTIME))
    /* We will #ifdef around the fprintf for machines
       we *know* are unsupported. (WDP 94/05)
    */
    fprintf(stderr, "NOTE: `elapsedtime' does nothing!\n");
    return 0.0;

# else /* not stumped */

/* "ftime" may be nicer, but "times" is more standard;
   but, on a Sun, if you do not get the SysV one, you are *hosed*...
 */

#  if defined(HAVE_TIMES) && ! sunos4_TARGET_OS
    struct tms t;
    clock_t r = times(&t);

    return (((double)r)/TicksPerSecond - ElapsedTimeStart);

#  else /* HAVE_FTIME */
    struct timeb t;

    ftime(&t);
    return (fabs(t.time + 1e-3*t.millitm - ElapsedTimeStart));

#  endif /* HAVE_FTIME */
# endif /* not stumped */
}
#endif /* !_WIN32 */

/* mut_user_time_during_GC() and mut_user_time()
 *
 * This function can be used to get the current mutator time *during*
 * a GC, i.e. between stat_startGC and stat_endGC.  This is used in
 * the heap profiler for accurately time stamping the heap sample.
 */
double
mut_user_time_during_GC(void)
{
  return (GC_start_time - GC_tot_time);
}

double
mut_user_time(void)
{
  return (usertime() - GC_tot_time);
}


static nat
pagefaults(void)
{
  /* ToDo (on NT): better, get this via the performance data
     that's stored in the registry. */
# if !defined(HAVE_GETRUSAGE) || irix_TARGET_OS || defined(_WIN32)
    return 0;
# else
    struct rusage t;

    getrusage(RUSAGE_SELF, &t);
    return(t.ru_majflt);
# endif
}

/* ToDo: use gettimeofday on systems that support it (u-sec accuracy) */

void
start_time(void)
{
#ifdef HAVE_SYSCONF
    long ticks;
    /* Determine TicksPerSecond ... */

    ticks = sysconf(_SC_CLK_TCK);
    if ( ticks == -1 ) {
	fprintf(stderr, "stat_init: bad call to 'sysconf'!\n");
    	stg_exit(EXIT_FAILURE);
    }
    TicksPerSecond = (double) ticks;

/* no "sysconf"; had better guess */
#elif defined(HZ)
    TicksPerSecond = (StgDouble) (HZ);

#elif defined(CLOCKS_PER_SEC)
    TicksPerSecond = (StgDouble) (CLOCKS_PER_SEC);
#else /* had better guess wildly */
    /* We will #ifdef around the fprintf for machines
       we *know* are unsupported. (WDP 94/05)
    */
    fprintf(stderr, "NOTE: Guessing `TicksPerSecond = 60'!\n");
    TicksPerSecond = 60.0;
#endif

    ElapsedTimeStart = elapsedtime();
}


void
initStats(void)
{
  nat i;
  FILE *sf = RtsFlags.GcFlags.statsFile;
  
  if (RtsFlags.GcFlags.giveStats >= VERBOSE_GC_STATS) {
    fprintf(sf, "    Alloc    Collect    Live    GC    GC     TOT     TOT  Page Flts\n");
    fprintf(sf, "    bytes     bytes     bytes  user  elap    user    elap\n");
  }
  GC_coll_times = 
    (double *)stgMallocBytes(sizeof(double) * RtsFlags.GcFlags.generations,
			   "initStats");
  for (i = 0; i < RtsFlags.GcFlags.generations; i++) {
    GC_coll_times[i] = 0.0;
  }
}    

#ifdef _WIN32
double
usertime(void)
{
    FILETIME creationTime, exitTime, kernelTime, userTime;
    long long int uT;

    /* Convert FILETIMEs into long longs */

    if (!GetProcessTimes (GetCurrentProcess(), &creationTime,
		          &exitTime, &kernelTime, &userTime)) {
	/* Probably exec'ing this on a Win95 box..*/
	return 0;
    }

    FT2longlong(uT,userTime);
    return (((StgDouble)uT)/TicksPerSecond);
}
#else

double
usertime(void)
{
# if ! (defined(HAVE_GETRUSAGE) || defined(HAVE_TIMES))
    /* We will #ifdef around the fprintf for machines
       we *know* are unsupported. (WDP 94/05)
    */
    fprintf(stderr, "NOTE: `usertime' does nothing!\n");
    return 0.0;

# else /* not stumped */

#  if defined(HAVE_TIMES) 
    struct tms t;

    times(&t);
    return(((double)(t.tms_utime))/TicksPerSecond);

#  else /* HAVE_GETRUSAGE */
    struct rusage t;

    getrusage(RUSAGE_SELF, &t);
    return(t.ru_utime.tv_sec + 1e-6*t.ru_utime.tv_usec);

#  endif /* HAVE_GETRUSAGE */
# endif /* not stumped */
}
#endif /* ! _WIN32 */

void 
end_init(void)
{
  InitUserTime = usertime();
  InitElapsedTime = elapsedtime();
  if (InitElapsedTime < 0.0) {
    InitElapsedTime = 0.0;
  }
}

/* -----------------------------------------------------------------------------
   Called at the beginning of each GC
   -------------------------------------------------------------------------- */

static nat rub_bell = 0;

void
stat_startGC(void)
{
    FILE *sf = RtsFlags.GcFlags.statsFile;

    nat bell = RtsFlags.GcFlags.ringBell;

    if (bell) {
	if (bell > 1) {
	    fprintf(stderr, " GC ");
	    rub_bell = 1;
	} else {
	    fprintf(stderr, "\007");
	}
    }

    if (sf != NULL) {
	GC_start_time = usertime();
	GCe_start_time = elapsedtime();
	if (RtsFlags.GcFlags.giveStats) {
	  GC_start_faults = pagefaults();
	}
    }
}

/* -----------------------------------------------------------------------------
   Called at the end of each GC
   -------------------------------------------------------------------------- */

void
stat_endGC(lnat alloc, lnat collect, lnat live, lnat copied, lnat gen)
{
    FILE *sf = RtsFlags.GcFlags.statsFile;

    if (sf != NULL) {
	double time = usertime();
	double etime = elapsedtime();

	if (RtsFlags.GcFlags.giveStats >= VERBOSE_GC_STATS) {
	    nat faults = pagefaults();

	    fprintf(sf, "%9ld %9ld %9ld",
		    alloc*sizeof(W_), collect*sizeof(W_), live*sizeof(W_));
	    fprintf(sf, " %5.2f %5.2f %7.2f %7.2f %4ld %4ld  (Gen: %2ld)\n", 
		    (time-GC_start_time), 
		    (etime-GCe_start_time), 
		    time,
		    etime,
		    faults - GC_start_faults,
		    GC_start_faults - GC_end_faults,
		    gen);

	    GC_end_faults = faults;
	    fflush(sf);
	}

	GC_coll_times[gen] += time-GC_start_time;

	GC_tot_copied += (ullong) copied;
	GC_tot_alloc  += (ullong) alloc;
	GC_tot_time   += time-GC_start_time;
	GCe_tot_time  += etime-GCe_start_time;

	if (gen == RtsFlags.GcFlags.generations-1) { /* major GC? */
	  if (live > MaxResidency) {
	    MaxResidency = live;
	  }
	  ResidencySamples++;
	}
    }

    if (rub_bell) {
	fprintf(stderr, "\b\b\b  \b\b\b");
	rub_bell = 0;
    }
}

/* -----------------------------------------------------------------------------
   Called at the end of execution

   NOTE: number of allocations is not entirely accurate: it doesn't
   take into account the few bytes at the end of the heap that
   were left unused when the heap-check failed.
   -------------------------------------------------------------------------- */

void
stat_exit(int alloc)
{
    FILE *sf = RtsFlags.GcFlags.statsFile;

    if (sf != NULL){
	char temp[BIG_STRING_LEN];
	double time = usertime();
	double etime = elapsedtime();
	double MutTime, MutElapsedTime;

	/* avoid divide by zero if time is measured as 0.00 seconds -- SDM */
	if (time  == 0.0)  time = 0.0001;
	if (etime == 0.0) etime = 0.0001;
	

	fprintf(sf, "%9ld %9.9s %9.9s",
		(lnat)alloc*sizeof(W_), "", "");
	fprintf(sf, " %5.2f %5.2f\n\n", 0.0, 0.0);

	GC_tot_alloc += alloc;

	ullong_format_string(GC_tot_alloc*sizeof(W_), temp, rtsTrue/*commas*/);
	fprintf(sf, "%11s bytes allocated in the heap\n", temp);

	ullong_format_string(GC_tot_copied*sizeof(W_), temp, rtsTrue/*commas*/);
	fprintf(sf, "%11s bytes copied during GC\n", temp);

	if ( ResidencySamples > 0 ) {
	    ullong_format_string(MaxResidency*sizeof(W_), temp, rtsTrue/*commas*/);
	    fprintf(sf, "%11s bytes maximum residency (%ld sample(s))\n",
			      temp,
			      ResidencySamples);
	}
	fprintf(sf,"\n");

	{ /* Count garbage collections */
	  nat g;
	  for (g = 0; g < RtsFlags.GcFlags.generations; g++) {
	    fprintf(sf, "%11d collections in generation %d (%6.2fs)\n", 
		    generations[g].collections, g, GC_coll_times[g]);
	  }
	}
	fprintf(sf,"\n%11ld Mb total memory in use\n\n", 
		mblocks_allocated * MBLOCK_SIZE / (1024 * 1024));

	MutTime = time - GC_tot_time - InitUserTime;
	if (MutTime < 0) { MutTime = 0; }
	MutElapsedTime = etime - GCe_tot_time - InitElapsedTime;
	if (MutElapsedTime < 0) { MutElapsedTime = 0; }	/* sometimes -0.00 */

	fprintf(sf, "  INIT  time  %6.2fs  (%6.2fs elapsed)\n",
		InitUserTime, InitElapsedTime);
	fprintf(sf, "  MUT   time  %6.2fs  (%6.2fs elapsed)\n",
		MutTime, MutElapsedTime);
	fprintf(sf, "  GC    time  %6.2fs  (%6.2fs elapsed)\n",
		GC_tot_time, GCe_tot_time);
	fprintf(sf, "  Total time  %6.2fs  (%6.2fs elapsed)\n\n",
		time, etime);

	fprintf(sf, "  %%GC time     %5.1f%%  (%.1f%% elapsed)\n\n",
		GC_tot_time*100./time, GCe_tot_time*100./etime);

	if (time - GC_tot_time == 0.0)
		ullong_format_string(0, temp, rtsTrue/*commas*/);
	else
		ullong_format_string((ullong)(GC_tot_alloc*sizeof(W_)/
					      (time - GC_tot_time)),
				     temp, rtsTrue/*commas*/);

	fprintf(sf, "  Alloc rate    %s bytes per MUT second\n\n", temp);

	fprintf(sf, "  Productivity %5.1f%% of total user, %.1f%% of total elapsed\n\n",
		(time - GC_tot_time - InitUserTime) * 100. / time, 
                (time - GC_tot_time - InitUserTime) * 100. / etime);
	fflush(sf);
	fclose(sf);
    }
}

/* -----------------------------------------------------------------------------
   stat_describe_gens

   Produce some detailed info on the state of the generational GC.
   -------------------------------------------------------------------------- */
void
stat_describe_gens(void)
{
  nat g, s, mut, mut_once, lge, live;
  StgMutClosure *m;
  bdescr *bd;
  step *step;

  fprintf(stderr, "     Gen    Steps      Max   Mutable  Mut-Once  Step   Blocks     Live    Large\n                    Blocks  Closures  Closures                         Objects\n");

  for (g = 0; g < RtsFlags.GcFlags.generations; g++) {
    for (m = generations[g].mut_list, mut = 0; m != END_MUT_LIST; 
	 m = m->mut_link) 
      mut++;
    for (m = generations[g].mut_once_list, mut_once = 0; m != END_MUT_LIST; 
	 m = m->mut_link) 
      mut_once++;
    fprintf(stderr, "%8d %8d %8d %9d %9d", g, generations[g].n_steps,
	    generations[g].max_blocks, mut, mut_once);

    for (s = 0; s < generations[g].n_steps; s++) {
      step = &generations[g].steps[s];
      for (bd = step->large_objects, lge = 0; bd; bd = bd->link)
	lge++;
      live = 0;
      if (RtsFlags.GcFlags.generations == 1) {
	bd = step->to_space;
      } else {
	bd = step->blocks;
      }
      for (; bd; bd = bd->link) {
	live += (bd->free - bd->start) * sizeof(W_);
      }
      if (s != 0) {
	fprintf(stderr,"%46s","");
      }
      fprintf(stderr,"%6d %8d %8d %8d\n", s, step->n_blocks,
	      live, lge);
    }
  }
  fprintf(stderr,"\n");
}
