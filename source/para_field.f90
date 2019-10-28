! Copyright 2012-2018, University of Strathclyde
! Authors: Lawrence T. Campbell
! License: BSD-3-Clause

!> @author
!> Lawrence Campbell,
!> University of Strathclyde,
!> Glasgow, UK
!> @brief
!> Module controlling the field mesh parallelism in Puffin

module ParaField


use paratype
use globals
use ParallelSetUp
use TransformInfoType
use gtop2
use filetype

implicit none

real(kind=wp), allocatable :: fr_rfield(:), bk_rfield(:), ac_rfield(:), &
                              fr_ifield(:), bk_ifield(:), ac_ifield(:), &
                              tre_fft(:), tim_fft(:)

real(kind=wp), allocatable :: tmp_A(:)

integer(kind=ip), allocatable :: recvs_pf(:), displs_pf(:), recvs_ff(:), &
                                 displs_ff(:), recvs_ef(:), displs_ef(:)

integer(kind=ip), allocatable :: recvs_ppf(:), displs_ppf(:), recvs_fpf(:), &
                                 displs_fpf(:), recvs_epf(:), displs_epf(:)

integer(kind=ip) :: fz2, ez2, lTr, bz2, fbuffLen, fbuffLenM, tllen, mainlen, &
                    fz2_GGG, ez2_GGG, bz2PB

integer(kind=ip) :: ffs, ffe, tlflen, ees, eee, tlelen, tlflen_glob, tlelen_glob, &
                    tlflen4arr, tlelen4arr, ffs_GGG, ffe_GGG, ees_GGG, eee_GGG



!!!   For parallel algorithm to deal with over-compression...

integer(kind=ip), allocatable :: lrank_v(:), rrank_v(:,:), &
                                 lrfromwhere(:)

integer(kind=ip) :: nsnds_bf, nrecvs_bf

logical :: qUnique

! if fz2 to ez2 overlaps, give warning - but not fail...
! No, fz2 to ez2 will only overlap if less nodes than procs...
! in which case, we share ALL nodes...but do this later...
! and can use MPI_ALLGATHER or whatever as before (but on
! ac_rfield and ac_ifield rather than sA)

! if boundary overlaps next process, then process will send
! buffer to more than one process...so loop around lrank_v
! and rrank_v etc




integer(kind=ip), allocatable :: ac_ar(:,:), ff_ar(:,:), ee_ar(:,:), &
                                 ft_ar(:,:)


integer(kind=ip) :: iParaBas   ! Basis for parallelism - options:

integer(kind=ip), parameter :: iElectronBased=1, &
                               iFieldBased = 2, &
                               iFFTW_based = 3



! C. Lechner (DESY), 20191016: dbg dump ID local to each MPI process
integer(kind=wp) :: dbgdumpid_cl=0


logical :: qStart_new

contains


	subroutine getLocalFieldIndices(sdz)

    implicit none

!     Setup local field pointers. These describe how the field is
!     parallelized. For now, only set up constant field barriers to
!     test a short 1D run. Field boundaries are decided by the
!     positions of electrons on adjecent processes, to ensure no
!     overlap (except at the 'boundaries').
!
!     Then can get more sophisticated...
!         1) Call more often to rearrange the grid and
!            provide a 'moving frame' for the electrons.
!
!         2) Can define bounds as averages between processes,
!            or start to share electrons between processes.

    real(kind=wp), intent(in) :: sdz

    real(kind=wp), allocatable :: sp2(:), fr_rfield_old(:), &
                                  fr_ifield_old(:), &
                                  bk_rfield_old(:), &
                                  bk_ifield_old(:), &
                                  ac_rfield_old(:), &
                                  ac_ifield_old(:)

    integer(kind=ip) :: locN, ij
    integer(kind=ip) :: fz2_r, gath_v
    integer :: req, error, lrank, rrank
    integer sendstat(MPI_STATUS_SIZE)
    integer statr(MPI_STATUS_SIZE)



    integer(kind=ip) :: fz2_OLD, ez2_OLD, lTr_OLD, bz2_OLD, &
                        fbuffLen_OLD, fbuffLenM_OLD, tllen_OLD, &
                        mainlen_OLD

    integer(kind=ip) :: ffs_OLD, ffe_OLD, ees_OLD, eee_OLD

    integer(kind=ip), allocatable :: ee_ar_old(:,:), &
                                     ff_ar_old(:,:), &
                                     ac_ar_old(:,:)



    integer(kind=ip) :: tnjdlz2


    INTEGER(KIND=IPL) :: sendbuff, recvbuff
    INTEGER recvstat(MPI_STATUS_SIZE)

    real(kind=wp) :: lenz2

!    print*, 'INSIDE GETLOCALFIELDINDICES, SIZE OF SA IS ', size(sA)



!!!!!!&&*(&*(&CD*(S)))  INITIALIZING ONLY FOR TESTING!!!! WILL ONLY
!                       WORK WITH TEST CASE!!!!!

    if (qStart_new) then

      iParaBas = iFieldBased

      call getFStEnd()

!      tnjdlz2 = 400

!      fz2 = (tProcInfo_G%rank * tnjdlz2) + 1
!      ez2 = (tProcInfo_G%rank * tnjdlz2) + tnjdlz2
      bz2 = ez2

!      if (tProcInfo_G%rank == 1) then

!        ez2 = NZ2_G
!        tnjdlz2 = NZ2_G - tnjdlz2

!      end if

!      if (tProcInfo_G%rank == 1) bz2 = ez2

!      mainlen = tnjdlz2

      tlflen_glob = 0
      tlflen = 0
      tlflen4arr = 1
      ffs = 0
      ffe = 0


      tlelen_glob = 0
      tlelen = 0
      tlelen4arr = 1
      ees = 0
      eee = 0

      allocate(ee_ar(tProcInfo_G%size, 3))
      allocate(ff_ar(tProcInfo_G%size, 3))
      allocate(ac_ar(tProcInfo_G%size, 3))


      call setupLayoutArrs(mainlen, fz2, ez2, ac_ar)
      call setupLayoutArrs(tlflen, ffs, ffe, ff_ar)
      call setupLayoutArrs(tlelen, ees, eee, ee_ar)

!      print*, mainlen, fz2, ez2, ac_ar


      allocate(fr_rfield(tlflen4arr*ntrnds_G), &
                 fr_ifield(tlflen4arr*ntrnds_G))
      allocate(bk_rfield(tlelen4arr*ntrnds_G), &
               bk_ifield(tlelen4arr*ntrnds_G))

      allocate(ac_rfield(mainlen*ntrnds_G), &
               ac_ifield(mainlen*ntrnds_G))

!      ac_rfield = sA((fz2-1)*ntrnds_G + 1:bz2*ntrnds_G)
!      ac_ifield = sA((fz2 + NZ2_G-1)*ntrnds_G + 1: &
!                      (bz2 + NZ2_G)*ntrnds_G)


      ac_rfield = 0_wp
      ac_ifield = 0_wp

      fr_rfield = 0_wp
      fr_ifield = 0_wp
      bk_rfield = 0_wp
      bk_ifield = 0_wp

      qStart_new = .false.

      if (fieldMesh == iTemporal) iParaBas = iElectronBased
      qUnique = .true.

!      goto 1000

    else

      deallocate(recvs_pf, displs_pf, tmp_A)
      deallocate(recvs_ff, displs_ff, recvs_ef, displs_ef)
      deallocate(lrank_v, lrfromwhere)
      deallocate(rrank_v)

      deallocate(recvs_ppf, displs_ppf)
      deallocate(recvs_fpf, displs_fpf, recvs_epf, displs_epf)

    end if


!!!   APPLY PERIODIC BOUNDS - PROBABLY A BETTER PLACE FOR THIS....

    if (FieldMesh == iPeriodic) then
      lenz2 = sLengthOfElmZ2_G * real((nz2_G - 1_ip), kind=wp )
      sElZ2_G = sElZ2_G - (real(floor(sElZ2_G / lenz2), kind=wp) * lenz2 )
    end if


!  where (sElZ2_G > sLengthOfElmZ2_G * real((nz2_G - 1_ip), kind=wp ))
!
!    sElZ2_G = sElZ2_G - sLengthOfElmZ2_G * real((nz2_G - 1_ip), kind=wp )
!
!  end where

!  do idd = 1, size(sElZ2_G)
!    if (sElZ2_G(idd) > sLengthOfElmZ2_G * real((nz2_G - 1_ip), kind=wp )) then
!      print*, 'REBOUNDING!!!'
!      sElZ2_G(idd) = sElZ2_G(idd) - 
!    end if
!  end do



  allocate(ee_ar_old(tProcInfo_G%size, 3))
  allocate(ff_ar_old(tProcInfo_G%size, 3))
  allocate(ac_ar_old(tProcInfo_G%size, 3))

  ee_ar_old = ee_ar
  ff_ar_old = ff_ar
  ac_ar_old = ac_ar



  call getFStEnd()    ! Define new 'active' region







  call setupLayoutArrs(mainlen, fz2, ez2, ac_ar)





  !if (iParaBas /= iFFTW_based) then

  if (qUnique) call rearrElecs()   ! Rearrange electrons



  call calcBuff(4 * pi * sRho_G * sdz)  ! Calculate buffers
!  call calcBuff(4.0_wp)  ! Calculate buffers

 ! else

!    bz2 = ez2

  !end if




  call getFrBk()  ! Get surrounding nodes


  call setupLayoutArrs(tlflen, ffs, ffe, ff_ar)
  call setupLayoutArrs(tlelen, ees, eee, ee_ar)


  if (.not. qUnique) then

    ac_ar(1,1) = mainlen
    ac_ar(1,2) = fz2
    ac_ar(1,3) = ez2
    ac_ar(2:tProcInfo_G%size,:) = 0

  end if


!  print*, 'trying to get layout of main as', fz2, ez2, bz2

!print*, 'AC_AR_OLD', ac_ar_old


! for each front, active and back (9 calls??)


  allocate(fr_rfield_old(size(fr_rfield)), fr_ifield_old(size(fr_ifield)))
  allocate(bk_rfield_old(size(bk_rfield)), bk_ifield_old(size(bk_ifield)))
  allocate(ac_rfield_old(size(ac_rfield)), ac_ifield_old(size(ac_ifield)))

  fr_rfield_old = fr_rfield
  fr_ifield_old = fr_ifield
  bk_rfield_old = bk_rfield
  bk_ifield_old = bk_ifield
  ac_rfield_old = ac_rfield
  ac_ifield_old = ac_ifield

  deallocate(ac_rfield, ac_ifield)
  deallocate(fr_rfield, fr_ifield)
  deallocate(bk_rfield, bk_ifield)

  allocate(fr_rfield(tlflen4arr*ntrnds_G), &
           fr_ifield(tlflen4arr*ntrnds_G))
  allocate(bk_rfield(tlelen4arr*ntrnds_G), &
           bk_ifield(tlelen4arr*ntrnds_G))
  allocate(ac_rfield(tllen*ntrnds_G), &
           ac_ifield(tllen*ntrnds_G))

  ac_rfield = 0_wp
  ac_ifield = 0_wp

  bk_rfield = 0_wp
  bk_ifield = 0_wp
  fr_rfield = 0_wp
  fr_ifield = 0_wp


  call redist2new2(ff_ar_old, ff_ar, fr_rfield_old, fr_rfield)
  call redist2new2(ff_ar_old, ff_ar, fr_ifield_old, fr_ifield)

  call redist2new2(ee_ar_old, ff_ar, bk_rfield_old, fr_rfield)
  call redist2new2(ee_ar_old, ff_ar, bk_ifield_old, fr_ifield)

  call redist2new2(ac_ar_old, ff_ar, ac_rfield_old, fr_rfield)
  call redist2new2(ac_ar_old, ff_ar, ac_ifield_old, fr_ifield)





  call redist2new2(ff_ar_old, ee_ar, fr_rfield_old, bk_rfield)
  call redist2new2(ff_ar_old, ee_ar, fr_ifield_old, bk_ifield)

  call redist2new2(ee_ar_old, ee_ar, bk_rfield_old, bk_rfield)
  call redist2new2(ee_ar_old, ee_ar, bk_ifield_old, bk_ifield)


  call redist2new2(ac_ar_old, ee_ar, ac_rfield_old, bk_rfield)
  call redist2new2(ac_ar_old, ee_ar, ac_ifield_old, bk_ifield)

!  call mpi_finalize(error)
!  stop





  call redist2new2(ff_ar_old, ac_ar, fr_rfield_old, ac_rfield)
  call redist2new2(ff_ar_old, ac_ar, fr_ifield_old, ac_ifield)

  call redist2new2(ee_ar_old, ac_ar, bk_rfield_old, ac_rfield)
  call redist2new2(ee_ar_old, ac_ar, bk_ifield_old, ac_ifield)

  call redist2new2(ac_ar_old, ac_ar, ac_rfield_old, ac_rfield)
  call redist2new2(ac_ar_old, ac_ar, ac_ifield_old, ac_ifield)




  deallocate(ff_ar_old, &
             ee_ar_old, &
             ac_ar_old)


  deallocate(ac_rfield_old, ac_ifield_old)
  deallocate(fr_rfield_old, fr_ifield_old)
  deallocate(bk_rfield_old, bk_ifield_old)


  if (.not. qUnique) then

    call MPI_Bcast(ac_rfield, tllen*ntrnds_G, &
                   mpi_double_precision, 0, &
                   tProcInfo_G%comm, error)

    call MPI_Bcast(ac_ifield, tllen*ntrnds_G, &
                   mpi_double_precision, 0, &
                   tProcInfo_G%comm, error)
  end if


! then deallocate old fields

! then redist electrons for new layout


!$$$$$$$$$$$$$$$$$%%%^^^^^^^^^FFFFFFFFFFFFFFFFF




!  #######################################################################
!     Get gathering arrays - only used to gather active field sections
!     back to GLOBAL field (the full field array on each process...)
!     Will NOT be needed later on....
!     ...and should now ONLY be used for data writing while testing...



      if (tProcInfo_G%rank /= tProcInfo_G%size-1) then
        gath_v = tlflen*ntrnds_G !-1
      else
        gath_v = tlflen*ntrnds_G
      end if


      allocate(recvs_ff(tProcInfo_G%size), displs_ff(tProcInfo_G%size))
      call getGathArrs(gath_v, recvs_ff, displs_ff)





      if (tProcInfo_G%rank /= tProcInfo_G%size-1) then
        gath_v = mainlen*ntrnds_G ! -1
      else
        gath_v = mainlen*ntrnds_G
      end if

      allocate(recvs_pf(tProcInfo_G%size), displs_pf(tProcInfo_G%size))
      call getGathArrs(gath_v, recvs_pf, displs_pf)



      if (tProcInfo_G%rank /= tProcInfo_G%size-1) then
        gath_v = tlelen*ntrnds_G !-1
      else
        gath_v = tlelen*ntrnds_G
      end if

      allocate(recvs_ef(tProcInfo_G%size), displs_ef(tProcInfo_G%size))
      call getGathArrs(gath_v, recvs_ef, displs_ef)









!  #######################################################################
!     Get gathering arrays - only used to gather active field sections
!   THESE ARE FOR POWER



      if (tProcInfo_G%rank /= tProcInfo_G%size-1) then
        gath_v = tlflen !-1
      else
        gath_v = tlflen
      end if


      allocate(recvs_fpf(tProcInfo_G%size), displs_fpf(tProcInfo_G%size))
      recvs_fpf = 0
      displs_fpf = 0
      call getGathArrs(gath_v, recvs_fpf, displs_fpf)





      if (tProcInfo_G%rank /= tProcInfo_G%size-1) then
        gath_v = mainlen ! -1
      else
        gath_v = mainlen
      end if

      allocate(recvs_ppf(tProcInfo_G%size), displs_ppf(tProcInfo_G%size))
      recvs_ppf = 0
      displs_ppf = 0
      call getGathArrs(gath_v, recvs_ppf, displs_ppf)



      if (tProcInfo_G%rank /= tProcInfo_G%size-1) then
        gath_v = tlelen !-1
      else
        gath_v = tlelen
      end if

      allocate(recvs_epf(tProcInfo_G%size), displs_epf(tProcInfo_G%size))
      recvs_epf = 0
      displs_epf = 0
      call getGathArrs(gath_v, recvs_epf, displs_epf)




!  #######################################################################







      ! Allocate back, front and active fields....commented out!
      ! ONLY USING ACTIVE FIELD FOR NOW TO CHECK SCALING...TO SEE
      ! IF IT'S WORTH PERSUING THIS METHOD
!      allocate(fr_rfield(tlflen), bk_rfield(tlelen), &
!               fr_ifield(tlflen), bk_ifield(tlelen))

!      allocate(ac_rfield(tllen), &
!               ac_ifield(tllen))

!      ac_rfield = sA(fz2:bz2)
!      ac_ifield = sA(fz2 + NZ2_G:bz2 + NZ2_G)

!      print*, 'INSIDE GETLOCALFIELDINDICES, SIZE OF SA AT 5 IS ', size(sA), &
!              ' FOR PROCESSOR ', tProcInfo_G%rank


  call mpi_barrier(tProcInfo_G%comm, error)

!  print*, tProcInfo_G%rank, ' made it here, with active nodes redefined between ', &
!                              fz2, ez2, 'corresponding to z2 = ', (fz2-1)*sLengthOfElmZ2_G, &
!                              ' to ', (ez2-1)*sLengthOfElmZ2_G

!  print*, 'and sizes of elecs = ', iNumberElectrons_G

!  print*, 'and rank = ', ' had buffer at global node ', bz2

!  print*, tProcInfo_G%rank, ': len of buffM = ', fbuffLen, fbuffLenM

!  print*, tProcInfo_G%rank, '...now front and back has ...', ffs, ffe, ees, eee

!  if (tProcInfo_G%rank == 0) print*, fr_rfield

!if (tProcInfo_G%rank == 1) print*, size(sElZ2_G), sElZ2_G

  !call mpi_finalize(error)
  !stop



    IF (tProcInfo_G%rank == tProcInfo_G%size-1) THEN
       rrank = 0
       lrank = tProcInfo_G%rank-1
    ELSE IF (tProcInfo_G%rank==0) THEN
       rrank = tProcInfo_G%rank+1
       lrank = tProcInfo_G%size-1
    ELSE
       rrank = tProcInfo_G%rank+1
       lrank = tProcInfo_G%rank-1
    END IF


    procelectrons_G(1) = iNumberElectrons_G

    sendbuff = iNumberElectrons_G
    recvbuff = iNumberElectrons_G

    if (tProcInfo_G%size > 1_ip) then

      do ij=2,tProcInfo_G%size
         call MPI_ISSEND( sendbuff,1,MPI_INT_HIGH,rrank,&
              0,tProcInfo_G%comm,req,error )
         call MPI_RECV( recvbuff,1,MPI_INT_HIGH,lrank,&
              0,tProcInfo_G%comm,recvstat,error )
         call MPI_WAIT( req,sendstat,error )
         procelectrons_G(ij) = recvbuff
         sendbuff=recvbuff
      end do

    end if



    if (qUnique) then

      allocate(tmp_A(maxval(lrank_v)*ntrndsi_G))

    else
      allocate(tmp_A(tllen*ntrndsi_G))
    end if


      ! allocate(tmp_A(fbuffLenM))

     tmp_A = 0_wp


!      print*, tProcInfo_G%rank, ' set up with bounds of ', fz2, ez2, bz2! , &

      call pupd8(ac_rfield, ac_ifield)

      qPArrOK_G = .true.
!      'with a buffer length of ', fbuffLen, 'and a total length of ', tllen
      !print*, tProcInfo_G%rank, ' and size of sA (over 2) is ', size(sA) / 2

    end subroutine getLocalFieldIndices


!  ###################################################


    subroutine UpdateGlobalField(sA)

      real(kind=wp), intent(inout) :: sA(:)

      real(kind=wp), allocatable :: A_local(:)

      integer(kind=ip) :: gath_v

      integer error


      if (ffe_GGG > 0) then

        if (tProcInfo_G%rank /= tProcInfo_G%size-1) then
          gath_v = tlflen*ntrnds_G  !-1
        else
          gath_v = tlflen*ntrnds_G
        end if




        allocate(A_local(gath_v))

        A_local = 0_wp

        A_local(1:gath_v) = fr_rfield(1:gath_v)
        !A_local(gath_v+1:gath_v*2) = fr_ifield(1:gath_v)

        call gather1A(A_local, sA((ffs_GGG-1)*ntrnds_G + 1:ffe_GGG*ntrnds_G), &
                gath_v, (ffe_GGG - ffs_GGG + 1) * ntrnds_G, &
                  recvs_ff, displs_ff)



        A_local(1:gath_v) = fr_ifield(1:gath_v)

        call gather1A(A_local, sA((ffs_GGG-1)*ntrnds_G + 1 + NZ2_G*ntrnds_G: &
                                    ffe_GGG*ntrnds_G + NZ2_G*ntrnds_G), &
                gath_v, (ffe_GGG - ffs_GGG + 1) * ntrnds_G, &
                 recvs_ff, displs_ff)





        deallocate(A_local)

      end if















      if (tProcInfo_G%rank /= tProcInfo_G%size-1) then
      	gath_v = mainlen * ntrnds_G !-1
      else
        gath_v = mainlen * ntrnds_G
      end if




      allocate(A_local(gath_v))

      A_local = 0_wp

      A_local(1:gath_v) = ac_rfield(1:gath_v)
!      A_local(gath_v+1:gath_v*2) = ac_ifield(1:gath_v)

      call gather1A(A_local, sA((fz2_GGG-1)*ntrnds_G + 1:ez2_GGG*ntrnds_G), &
                       gath_v, (fz2_GGG - ez2_GGG + 1) * ntrnds_G, &
                       recvs_pf, displs_pf)

      A_local(1:gath_v) = ac_ifield(1:gath_v)

      call gather1A(A_local, sA((fz2_GGG-1)*ntrnds_G + 1 + NZ2_G*ntrnds_G: &
                                 ez2_GGG*ntrnds_G + NZ2_G*ntrnds_G), &
                       gath_v, (ez2_GGG - fz2_GGG + 1) * ntrnds_G, &
                       recvs_pf, displs_pf)



      deallocate(A_local)


      if (eee_GGG < nz2_G) then

        if (tProcInfo_G%rank /= tProcInfo_G%size-1) then
          gath_v = tlelen * ntrnds_G !-1
        else
          gath_v = tlelen * ntrnds_G
        end if




        allocate(A_local(gath_v))

          A_local = 0_wp

          A_local(1:gath_v) = fr_rfield(1:gath_v)
          !A_local(gath_v+1:gath_v*2) = fr_ifield(1:gath_v)

        call gather1A(A_local, sA((ees_GGG - 1)*ntrnds_G + 1:eee_GGG*ntrnds_G), &
                       gath_v, (eee_GGG - ees_GGG + 1), recvs_ef, displs_ef)


        A_local(1:gath_v) = fr_ifield(1:gath_v)

        call gather1A(A_local, sA((ees_GGG - 1)*ntrnds_G + 1 + NZ2_G*ntrnds_G: &
                       eee_GGG*ntrnds_G + nz2_G*ntrnds_G), &
                       gath_v, (eee_GGG - ees_GGG + 1), recvs_ef, displs_ef)



        deallocate(A_local)

      end if

    end subroutine UpdateGlobalField








    subroutine UpdateGlobalPow(fpow, apow, bpow, gpow)

      real(kind=wp), intent(inout) :: fpow(:), apow(:), bpow(:), gpow(:)

      integer(kind=ip) :: gath_v

      real(kind=wp), allocatable :: A_local(:), powi(:)

      integer :: error

      gpow=0.0_wp

!      if (ffe_GGG > 0) then
      if ((ffe_GGG - ffs_GGG) > 0) then

        if (tProcInfo_G%rank /= tProcInfo_G%size-1) then
          gath_v = tlflen  !-1
        else
          gath_v = tlflen
        end if




        allocate(A_local(gath_v))

        A_local = 0_wp

        A_local(1:gath_v) = fpow(1:gath_v)
        !A_local(gath_v+1:gath_v*2) = fr_ifield(1:gath_v)

        call gather1A(A_local, gpow(ffs_GGG:ffe_GGG), &
                gath_v, ffe_GGG - ffs_GGG + 1, &
                  recvs_fpf, displs_fpf)


        deallocate(A_local)

      end if





!    call mpi_barrier(tProcInfo_G%comm, error)
!    print*, 'got glob powwww  almosst 1'




      if (tProcInfo_G%rank /= tProcInfo_G%size-1) then
        gath_v = mainlen !-1
      else
        gath_v = mainlen
      end if




      allocate(A_local(gath_v))
      allocate(powi(ez2_GGG - fz2_GGG + 1))

      A_local = 0_wp
      powi = 0_wp

      A_local(1:gath_v) = apow(1:gath_v)
!      A_local(gath_v+1:gath_v*2) = ac_ifield(1:gath_v)

      if (qUnique) then
        call gather1A(A_local, powi, &
                       gath_v, fz2_GGG - ez2_GGG + 1, &
                       recvs_ppf, displs_ppf)
      else
        powi = A_local
      end if


      gpow(fz2_GGG:ez2_GGG) = powi(:)
      deallocate(A_local)
      deallocate(powi)

    !if (tProcInfo_G%qRoot) print*, gpow



!    call mpi_barrier(tProcInfo_G%comm, error)
!    print*, 'got glob powwww  almosst 2'



!      if (eee_GGG < nz2_G+1) then
      if ( (eee_GGG - ees_GGG) > 0) then

        if (tProcInfo_G%rank /= tProcInfo_G%size-1) then
          gath_v = tlelen !-1
        else
          gath_v = tlelen
        end if




        allocate(A_local(gath_v))
        allocate(powi(eee_GGG - ees_GGG + 1))


          A_local = 0_wp
          powi = 0_wp

          A_local(1:gath_v) = bpow(1:gath_v)
          !A_local(gath_v+1:gath_v*2) = fr_ifield(1:gath_v)

          call gather1A(A_local, powi, &
                         gath_v, eee_GGG - ees_GGG + 1, recvs_epf, displs_epf)


          gpow(ees_GGG:eee_GGG) = powi(:)

          deallocate(A_local)
          deallocate(powi)

      end if

!    call mpi_barrier(tProcInfo_G%comm, error)
!    print*, 'got glob powwww  almosst 3'



    end subroutine UpdateGlobalPow

!  ###################################################


    subroutine alloc_paraf_inds()

      allocate(ac_ar(tProcInfo_G%size, 3))
      allocate(ff_ar(tProcInfo_G%size, 3))
      allocate(ee_ar(tProcInfo_G%size, 3))

    end subroutine alloc_paraf_inds




    subroutine upd8da(dadz_r, dadz_i)

    ! Send dadz from buffer to MPI process on the right
    ! Data is added to array in next process, not
    ! written over.

      real(kind=wp), contiguous, intent(inout) :: dadz_r(:), dadz_i(:)

      integer :: req, error
      integer(kind=ip) :: ij, si, sst, sse
      integer statr(MPI_STATUS_SIZE)
      integer sendstat(MPI_STATUS_SIZE)

      real(kind=wp), allocatable :: Abounds(:)

      if (qUnique) then



        tmp_A = 0_wp
        !snd_A = 0_wp


   !           si = rrank_v(1, 1)
   !         sst = rrank_v(1, 2)
   !         sse = rrank_v(1, 3)
   !         call mpi_barrier(tProcInfo_G%comm, error)
   !         print*, tProcInfo_G%rank, 'here, sending nodes :', (sst - (fz2-1)-1)*ntrnds_G + 1, &
   !                       'to', (sse-(fz2-1))*ntrnds_G , 'to rank', tProcInfo_G%rank+1

        if (tProcInfo_G%rank /= tProcInfo_G%size-1) then

  !        send to rank+1

          !do ij = tProcInfo_G%rank + 1, tProcInfo_G%size-1
           do ij = 1, nsnds_bf

            si = rrank_v(ij, 1)
            sst = rrank_v(ij, 2)
            sse = rrank_v(ij, 3)


  !          call mpi_issend(dadz_r((ez2+1)-(fz2-1) + ofst :bz2-(fz2-1)), si, &
  !                    mpi_double_precision, &
  !                    tProcInfo_G%rank+1, 0, tProcInfo_G%comm, req, error)


!            print*, tProcInfo_G%rank, 'here, sending nodes :', (sst - (fz2-1)-1)*ntrnds_G + 1, &
!                          'to', (sse-(fz2-1))*ntrnds_G , 'to rank', tProcInfo_G%rank+ij, &
!                          ' and size dadz_r = ', size(dadz_r), ' and si =  ', si

            sst = (sst - (fz2-1)-1)*ntrndsi_G + 1
            sse = (sse-(fz2-1))*ntrndsi_G
            si = si*ntrndsi_G


            call mpi_issend(dadz_r(sst:sse), &
                      si, &
                      mpi_double_precision, &
                      tProcInfo_G%rank+ij, 0, tProcInfo_G%comm, req, error)


          end do


        end if

    !          call mpi_barrier(tProcInfo_G%comm, error)
     !         print*, tProcInfo_G%rank, 'here, recving nodes :', 1, &
      !                    'to', lrank_v(1)*ntrndsi_G , 'from rank', lrfromwhere(1)


        if (tProcInfo_G%rank /= 0) then

  !       rec from rank-1

          do ij = 1, nrecvs_bf


!              print*, tProcInfo_G%rank, 'here, recving nodes :', 1, &
!                          'to', lrank_v(ij)*ntrndsi_G , 'from rank', lrfromwhere(ij), &
!                          ' and size dadz_r = ', size(dadz_r)

            CALL mpi_recv( tmp_A(1:lrank_v(ij)*ntrndsi_G), &
                   lrank_v(ij)*ntrndsi_G, &
                   mpi_double_precision, &
            	     lrfromwhere(ij), 0, tProcInfo_G%comm, statr, error )

            dadz_r(1:lrank_v(ij)*ntrndsi_G) = dadz_r(1:lrank_v(ij)*ntrndsi_G) &
                                           + tmp_A(1:lrank_v(ij)*ntrndsi_G)

          end do

        end if

        if (tProcInfo_G%rank /= tProcInfo_G%size-1) call mpi_wait( req,sendstat,error )







        tmp_A = 0_wp

        if (tProcInfo_G%rank /= tProcInfo_G%size-1) then

  !        send to rank+1

          ! do ij = tProcInfo_G%rank + 1, tProcInfo_G%size-1
          do ij = 1, nsnds_bf

            si = rrank_v(ij, 1)
            sst = rrank_v(ij, 2)
            sse = rrank_v(ij, 3)


            sst = (sst - (fz2-1)-1)*ntrndsi_G + 1
            sse = (sse-(fz2-1))*ntrndsi_G
            si = si*ntrndsi_G

  !          call mpi_issend(dadz_r((ez2+1)-(fz2-1) + ofst :bz2-(fz2-1)), si, &
  !                    mpi_double_precision, &
  !                    tProcInfo_G%rank+1, 0, tProcInfo_G%comm, req, error)

            call mpi_issend(dadz_i(sst:sse), &
                      si, &
                      mpi_double_precision, &
                      tProcInfo_G%rank+ij, 0, tProcInfo_G%comm, req, error)


          end do

        end if



        if (tProcInfo_G%rank /= 0) then

  !       rec from rank-1

          do ij = 1, nrecvs_bf

            CALL mpi_recv( tmp_A(1:lrank_v(ij)*ntrndsi_G), &
                   lrank_v(ij)*ntrndsi_G, &
                   mpi_double_precision, &
                   lrfromwhere(ij), 0, tProcInfo_G%comm, statr, error )

            dadz_i(1:lrank_v(ij)*ntrndsi_G) = dadz_i(1:lrank_v(ij)*ntrndsi_G) &
                                           + tmp_A(1:lrank_v(ij)*ntrndsi_G)

          end do

        end if


        if (tProcInfo_G%rank /= tProcInfo_G%size-1) call mpi_wait( req,sendstat,error )

        !dadz_i(1:fbuffLenM) = dadz_i(1:fbuffLenM) + tmp_A


      else


        call mpi_reduce(dadz_r, tmp_A, mainlen*ntrndsi_G, &
                        mpi_double_precision, &
                        mpi_sum, 0, tProcInfo_G%comm, &
                        error)

        dadz_r = tmp_A


        call mpi_reduce(dadz_i, tmp_A, mainlen*ntrndsi_G, &
                        mpi_double_precision, &
                        mpi_sum, 0, tProcInfo_G%comm, &
                        error)

        dadz_i = tmp_A

      end if


!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!  PERIODIC BOUNDS - EXPERIMENTAL


      if (FieldMesh == iPeriodic) then

        if (.not. qUnique) then

!!!! IF PERIODIC

          si = ntrndsi_G * (bz2PB + 1_ip)
          sst = ((tllen - (bz2PB+1_ip) ) * ntrndsi_G) + 1_ip
          sse = tllen * ntrndsi_G
          if (ioutInfo_G > 0) print*, size(dadz_r), tllen, mainlen

          if (ioutInfo_G > 0) print*, 'IM NOT UNIQUE'

          dadz_r(1:si) = dadz_r(1:si) + dadz_r(sst:sse)
          dadz_i(1:si) = dadz_i(1:si) + dadz_i(sst:sse)


        else



          si = ntrndsi_G * (bz2PB + 1_ip)
          sst = ((tllen - (bz2PB + 1_ip) ) * ntrndsi_G) + 1_ip
          sse = tllen * ntrndsi_G

          if (tProcInfo_G%rank == tProcInfo_G%size-1_ip) then

              call mpi_issend(si, 1, mpi_integer, 0_ip, 0, &
                              tProcInfo_G%comm, req, error)

          end if

          if (tProcInfo_G%rank == 0) then

              call mpi_recv( si, 1, mpi_integer, tProcInfo_G%size-1_ip, 0, &
                             tProcInfo_G%comm, statr, error )

          end if

          if (tProcInfo_G%rank == tProcInfo_G%size-1_ip) then

            call mpi_issend(dadz_r(sst:sse), &
                            si, &
                            mpi_double_precision, &
                            0_ip, 0, &
                            tProcInfo_G%comm, req, error)

          end if


          if (tProcInfo_G%rank == 0) then

            allocate(Abounds(si))

            call mpi_recv( Abounds, si, mpi_double_precision, &
                     tProcInfo_G%size-1_ip, 0, tProcInfo_G%comm, &
                     statr, error )

            dadz_r(1:si) = dadz_r(1:si) + Abounds

          end if


          if (tProcInfo_G%rank == tProcInfo_G%size-1) then

            call mpi_wait( req,sendstat,error )
            call mpi_issend(dadz_i(sst:sse), si, mpi_double_precision, &
                            0_ip, 0, tProcInfo_G%comm, req, error)

          end if

          if (tProcInfo_G%rank == 0) then

            call mpi_recv( Abounds, si, mpi_double_precision, &
                      tProcInfo_G%size-1_ip, 0, tProcInfo_G%comm, &
                      statr, error )

            dadz_i(1:si) = dadz_i(1:si) + Abounds

            deallocate(Abounds) 

          end if


          if (tProcInfo_G%rank == tProcInfo_G%size-1) then

            call mpi_wait( req,sendstat,error )

          end if



       
          if (tProcInfo_G%rank == 0_ip) then
       
            call mpi_issend(dadz_r(1:si), si, mpi_double_precision, &
                            tProcInfo_G%size-1_ip, 0, &
                            tProcInfo_G%comm, req, error)

          end if



          if (tProcInfo_G%rank == tProcInfo_G%size-1_ip) then

            call mpi_recv( dadz_r(sst:sse), si, mpi_double_precision, &
                     0, 0, tProcInfo_G%comm, statr, error )
       
          end if


          if (tProcInfo_G%rank == 0_ip) then

            call mpi_wait( req,sendstat,error )
            call mpi_issend(dadz_i(1:si), si, mpi_double_precision, &
                            tProcInfo_G%size-1_ip, 0, &
                            tProcInfo_G%comm, req, error)

          end if


          if (tProcInfo_G%rank == tProcInfo_G%size-1_ip) then

            call mpi_recv( dadz_i(sst:sse), si, mpi_double_precision, &
                     0, 0, tProcInfo_G%comm, statr, error )

          end if


          if (tProcInfo_G%rank == 0_ip) then

            call mpi_wait( req,sendstat,error )

          end if

        end if  ! end periodic mesh for qUnique

      end if   ! End synch'ing for periodic mesh...

    end subroutine upd8da


!  ###################################################

!> @author
!> Lawrence Campbell,
!> University of Strathclyde, 
!> Glasgow, UK
!> @brief
!> Update the periodic boundary buffer for the periodic case

    subroutine pupd8(ar, ai)
      
      real(kind=wp), intent(inout) :: ar(:), ai(:)

      integer :: req, error
      integer(kind=ip) :: si, sst, sse
      integer statr(MPI_STATUS_SIZE)
      integer sendstat(MPI_STATUS_SIZE)

      if (FieldMesh == iPeriodic) then

        if (qUnique) then

          si = ntrnds_G * (bz2PB + 1_ip)
          sst = ((tllen - (bz2PB + 1_ip) ) * ntrnds_G) + 1_ip
          sse = tllen * ntrnds_G
          
          if (tProcInfo_G%rank == 0_ip) then
       
            call mpi_issend(ar(1:si), si, mpi_double_precision, &
                            tProcInfo_G%size-1_ip, 0, &
                            tProcInfo_G%comm, req, error)

          end if



          if (tProcInfo_G%rank == tProcInfo_G%size-1_ip) then

            call mpi_recv( ar(sst:sse), si, mpi_double_precision, &
                     0, 0, tProcInfo_G%comm, statr, error )
       
          end if


          if (tProcInfo_G%rank == 0_ip) then

            call mpi_wait( req,sendstat,error )
            call mpi_issend(ai(1:si), si, mpi_double_precision, &
                            tProcInfo_G%size-1_ip, 0, &
                            tProcInfo_G%comm, req, error)

          end if


          if (tProcInfo_G%rank == tProcInfo_G%size-1_ip) then

            call mpi_recv( ai(sst:sse), si, mpi_double_precision, &
                     0, 0, tProcInfo_G%comm, statr, error )

          end if


          if (tProcInfo_G%rank == 0_ip) then

            call mpi_wait( req,sendstat,error )

          end if
          
        end if
        
      end if
  
    end subroutine pupd8

!  ###################################################





    subroutine upd8a(ac_rl, ac_il)

      implicit none

    ! Send sA from buffer to process on the left
    ! Data in 'buffer' on the left is overwritten.

      real(kind=wp), contiguous, intent(inout) :: ac_rl(:), ac_il(:)

      integer(kind=ip) :: req, error, ij, si, sst, sse
      integer statr(MPI_STATUS_SIZE)
      integer sendstat(MPI_STATUS_SIZE)

!      real(kind=wp), allocatable :: tstf(:), tstf2(:)



      if (qUnique) then


        if (tProcInfo_G%rank /= 0) then

  !       rec from rank-1

          do ij = 1, nrecvs_bf

            CALL mpi_issend( ac_rl(1:lrank_v(ij)*ntrndsi_G), &
                   lrank_v(ij)*ntrndsi_G, &
                   mpi_double_precision, &
                   lrfromwhere(ij), 0, tProcInfo_G%comm, req, error )

          end do

        end if







        if (tProcInfo_G%rank /= tProcInfo_G%size-1) then

  !        send to rank+1

          !do ij = tProcInfo_G%rank + 1, tProcInfo_G%size-1
           do ij = 1, nsnds_bf

            si = rrank_v(ij, 1)
            sst = rrank_v(ij, 2)
            sse = rrank_v(ij, 3)

            sst = (sst - (fz2-1)-1)*ntrndsi_G + 1
            sse = (sse-(fz2-1))*ntrndsi_G
            si = si*ntrndsi_G

  !          call mpi_issend(dadz_r((ez2+1)-(fz2-1) + ofst :bz2-(fz2-1)), si, &
  !                    mpi_double_precision, &
  !                    tProcInfo_G%rank+1, 0, tProcInfo_G%comm, req, error)

            call mpi_recv(ac_rl(sst:sse), &
                      si, &
                      mpi_double_precision, &
                      tProcInfo_G%rank+ij, 0, tProcInfo_G%comm, statr, error)


          end do


        end if




        if (tProcInfo_G%rank /= 0) then

  !       rec from rank-1

          do ij = 1, nrecvs_bf

            CALL mpi_issend( ac_il(1:lrank_v(ij)*ntrndsi_G), &
                   lrank_v(ij)*ntrndsi_G, &
                   mpi_double_precision, &
                   lrfromwhere(ij), 0, tProcInfo_G%comm, req, error )

          end do

        end if







        if (tProcInfo_G%rank /= tProcInfo_G%size-1) then

  !        send to rank+1

          !do ij = tProcInfo_G%rank + 1, tProcInfo_G%size-1
           do ij = 1, nsnds_bf

            si = rrank_v(ij, 1)
            sst = rrank_v(ij, 2)
            sse = rrank_v(ij, 3)

            sst = (sst - (fz2-1)-1)*ntrndsi_G + 1
            sse = (sse-(fz2-1))*ntrndsi_G
            si = si*ntrndsi_G

  !          call mpi_issend(dadz_r((ez2+1)-(fz2-1) + ofst :bz2-(fz2-1)), si, &
  !                    mpi_double_precision, &
  !                    tProcInfo_G%rank+1, 0, tProcInfo_G%comm, req, error)

            call mpi_recv(ac_il( sst:sse ), &
                      si, &
                      mpi_double_precision, &
                      tProcInfo_G%rank+ij, 0, tProcInfo_G%comm, statr, error)


          end do


        end if


        if (tProcInfo_G%rank /= 0) call mpi_wait( req,sendstat,error )



      else


        call MPI_Bcast(ac_rl, tllen*ntrndsi_G, &
                       mpi_double_precision, 0, &
                       tProcInfo_G%comm, error)

        call MPI_Bcast(ac_il, tllen*ntrndsi_G, &
                       mpi_double_precision, 0, &
                       tProcInfo_G%comm, error)


      end if


!   -----     OLD

!      if (tProcInfo_G%rank /= 0) then
!
!!        send to rank-1
!
!        call mpi_issend(ac_rl(1:fbuffLenM), fbuffLenM, mpi_double_precision, &
!                           tProcInfo_G%rank-1, 0, tProcInfo_G%comm, req, error)
!
!      end if
!
!
!
!      if (tProcInfo_G%rank /= tProcInfo_G%size-1) then
!
!!       rec from rank+1
!
!        CALL mpi_recv( ac_rl((ez2+1)-(fz2-1):bz2-(fz2-1)), fbuffLen, mpi_double_precision, &
!                    tProcInfo_G%rank+1, 0, tProcInfo_G%comm, statr, error )
!
!      end if
!
!
!
!
!
!      if (tProcInfo_G%rank /= 0) call mpi_wait( req,sendstat,error )
!
!
!
!      if (tProcInfo_G%rank /= 0) then
!
!!        send to rank-1
!
!        call mpi_issend(ac_il(1:fbuffLenM), fbuffLenM, mpi_double_precision, &
!                tProcInfo_G%rank-1, 0, tProcInfo_G%comm, req, error)
!
!      end if
!
!      if (tProcInfo_G%rank /= tProcInfo_G%size-1) then
!
!!       rec from rank+1
!
!        CALL mpi_recv( ac_il((ez2+1)-(fz2-1):bz2-(fz2-1)), fbuffLen, mpi_double_precision, &
!               tProcInfo_G%rank+1, 0, tProcInfo_G%comm, statr, error )
!
!      end if
!
!      if (tProcInfo_G%rank /= 0) call mpi_wait( req,sendstat,error )
!
!   -----     OLD



    end subroutine upd8a






  subroutine inner2Outer(inner_ra, inner_ia)


    implicit none

    real(kind=wp), contiguous, intent(in) :: inner_ra(:), inner_ia(:)

    integer(kind=ip) :: iz, ssti, ssei, iy, sst, sse
    integer(kind=ip) :: nxout, nyout ! should be made global and calculated

    nxout = (nx_g - nspindx)/2
    nyout = (ny_g - nspindy)/2


    do iz = fz2, bz2

      do iy = 1, nspinDY

        sst = (iz - (fz2-1)-1)*ntrnds_G + &
                         nx_G*(nyout+(iy-1)) + &
                         nxout + 1

        sse = sst + nspinDX - 1

        ssti = (iz - (fz2-1)-1)*ntrndsi_G + &
                         nspinDX*(iy-1) + 1
        ssei = ssti + nspinDX - 1

        ac_rfield(sst:sse) = inner_ra(ssti:ssei)
        ac_ifield(sst:sse) = inner_ia(ssti:ssei)

      end do

    end do


  end subroutine inner2Outer





  subroutine outer2Inner(inner_ra, inner_ia)


    implicit none

    real(kind=wp), contiguous, intent(out) :: inner_ra(:), inner_ia(:)

    integer(kind=ip) :: iz, sst, sse, ssti, ssei
    integer(kind=ip) :: nxout, nyout, iy ! should be made global and calculated

    nxout = (nx_g - nspindx)/2
    nyout = (ny_g - nspindy)/2

    do iz = fz2, bz2

      do iy = 1, nspinDY

        sst = (iz - (fz2-1)-1)*ntrnds_G + &
                         nx_G*(nyout+(iy-1)) + &
                         nxout + 1

        sse = sst + nspinDX - 1

        ssti = (iz - (fz2-1)-1)*ntrndsi_G + &
                         nspinDX*(iy-1) + 1
        ssei = ssti + nspinDX - 1

        inner_ra(ssti:ssei) = ac_rfield(sst:sse)
        inner_ia(ssti:ssei) = ac_ifield(sst:sse)

      end do

    end do


  end subroutine outer2Inner


  subroutine getInNode()

  real(kind=wp) :: sminx, smaxx, sminy, smaxy
  integer(kind=ip) :: iminx, imaxx, iminy, imaxy, &
                      inBuf

  integer :: error
  logical :: qOKL

  inBuf = 3_ip

  if (iNumberElectrons_G > 0_ipl) then

    smaxx = abs(maxval(sElX_G))
    sminx = abs(minval(sElX_G))

    smaxy = abs(maxval(sElY_G))
    sminy = abs(minval(sElY_G))

    imaxx = ceiling(smaxx / sLengthOfElmX_G)
    iminx = floor(sminx / sLengthOfElmX_G)

    imaxy = ceiling(smaxy / sLengthOfElmY_G)
    iminy = floor(sminy / sLengthOfElmY_G)

    nspinDX = maxval((/imaxx,iminx/)) + inBuf
    nspinDY = maxval((/imaxy,iminy/)) + inBuf

    nspinDX = nspinDX * 2
    nspinDY = nspinDY * 2

  else   ! arbitrary minimum in case of zero MPs...

    nspinDX = 2_ipl
    nspinDY = 2_ipl

  end if

  if (mod(nx_g, 2) .ne. mod(nspinDX, 2) ) then

    nspinDX =  nspinDX + 1

  end if

  if (mod(ny_g, 2) .ne. mod(nspinDY, 2) ) then

    nspinDY =  nspinDY + 1

  end if



  call mpi_allreduce(MPI_IN_PLACE, nspinDX, 1, mpi_integer, &
                   mpi_max, tProcInfo_G%comm, error)

  call mpi_allreduce(MPI_IN_PLACE, nspinDY, 1, mpi_integer, &
                   mpi_max, tProcInfo_G%comm, error)

  if (nspinDX > nx_g) then
    print*, 'ERROR, x grid not large enough'
    print*, 'nspinDX = ', nspinDX
    call StopCode(qOKL)
  end if


  if (nspinDY > ny_g) then
    print*, 'ERROR, y grid not large enough'
    print*, 'nspinDY = ', nspinDY
    call StopCode(qOKL)
  end if


  ntrndsi_G = nspinDX * nspinDY

  qInnerXYOK_G = .true.

  end subroutine getInNode





  subroutine divNodes(ndpts, numproc, rank, &
                      locN, local_start, local_end)

! Get local number of nodes and start and global
! indices of start and end points.
!
!           ARGUMENTS

    integer(kind=ip), intent(in) :: ndpts, numproc, rank

    integer(kind=ip), intent(out) :: locN
    integer(kind=ip), intent(out) :: local_start, local_end

!          LOCAL ARGS

    real(kind=wp) :: frac
    integer(kind=ip) :: lowern, highern, remainder


    frac = REAL(ndpts)/REAL(numproc)
    lowern = FLOOR(frac)
    highern = CEILING(frac)
    remainder = MOD(ndpts,numproc)

    IF (remainder==0) THEN
       locN = lowern
    ELSE
       IF (rank < remainder) THEN
          locN = highern
       ELSE
          locN = lowern
       ENDIF
    ENDIF


!     Calculate local start and end values.

    IF (rank >= remainder) THEN

      local_start = (remainder*highern) + ((rank-remainder) * lowern) + 1
      local_end = local_start + locN - 1

    ELSE

      local_start = rank*locN + 1
      local_end = local_start + locN - 1

    ENDIF


  end subroutine divNodes















  subroutine golaps(iso, ieo, f_ar, f_send)

!     Calculate so e.g. f_send(1,1:3) holds number of nodes to c
!     send from local front array to front array of rank=0, and
!     the local start and end positions of what is being sent
!     from the local start array, respectively

! inputs

    integer(kind=ip), intent(in)  :: iso, ieo
    integer(kind=ip), intent(in)  :: f_ar(:,:)
    integer(kind=ip), intent(out) :: f_send(:,:)

! local args

    integer(kind=ip) :: iproc


!    print*, iso, ieo, size(f_send)

    do iproc = 0,tProcInfo_G%size-1

      f_send(iproc+1,1) = 0
      f_send(iproc+1,2) = 0
      f_send(iproc+1,3) = 0

      if (f_ar(iproc+1,1) > 0) then

        if ((ieo >= f_ar(iproc+1,2)) .and. (ieo <= f_ar(iproc+1,3) ) )  then ! end node between limits

          f_send(iproc+1,3) = ieo

          if (iso < f_ar(iproc+1,2)) f_send(iproc+1,2) = f_ar(iproc+1,2)    ! front node before first limit

          if (iso >= f_ar(iproc+1,2)) f_send(iproc+1,2) = iso   ! front node after first limit

          f_send(iproc+1,1) = f_send(iproc+1,3) - f_send(iproc+1,2) + 1

        else if ( (ieo >= f_ar(iproc+1,3)) .and.  (iso <= f_ar(iproc+1,3)))  then ! end node after last limit

          f_send(iproc+1, 3) = f_ar(iproc+1,3)

          if (iso < f_ar(iproc+1,2)) f_send(iproc+1,2) = f_ar(iproc+1,2)    ! front node before first limit

          if (iso >= f_ar(iproc+1,2)) f_send(iproc+1,2) = iso   ! front node after first limit

          f_send(iproc+1,1) = f_send(iproc+1,3) - f_send(iproc+1,2) + 1

        else      ! no overlap...

          f_send(iproc+1,1) = 0
          f_send(iproc+1,2) = 0
          f_send(iproc+1,3) = 0

        end if

      end if

    end do


  end subroutine golaps

















  subroutine calcBuff(dz)

! Subroutine to setup the 'buffer' region
! at the end of the parallel field section
! on this process.
!
! This is calculated by estimating how much
! will be needed by the electrons currently on the
! process. By calculating p2, one may estimate the
! size of the domain required in z2 to hold
! the electron macroparticles over a distance
! dz through the undulator.

    real(kind=wp), intent(in) :: dz
    real(kind=wp), allocatable :: sp2(:)

    real(kind=wp) :: bz2_len
    integer(kind=ip) :: yip, ij, bz2_globm, ctrecvs, cpolap, dum_recvs, &
                        maxbz2PB, bz2last
    integer(kind=ip), allocatable :: drecar(:)
    integer :: error, req

    integer :: kk

    integer statr(MPI_STATUS_SIZE)
    integer sendstat(MPI_STATUS_SIZE)

    character(64_IP) :: fn_dbg_dump ! CL dbg code
    character(64_IP) :: fn_dbg_dump_dumpno
    character(64_IP) :: fn_dbg_dump_mpirank

    ! get buffer location

    if (iNumberElectrons_G > 0_ipl) then

      allocate(sp2(iNumberElectrons_G))

      call getP2(sp2, sElGam_G, sElPX_G, sElPY_G, sEta_G, sGammaR_G, sAw_G)

      bz2_len = dz  ! distance in zbar until next rearrangement
      bz2_len = maxval(sElZ2_G + bz2_len * sp2)  ! predicted length in z2 needed needed in buffer for beam

! C. Lechner (DESY) dbg code, 20191016
      dbgdumpid_cl=dbgdumpid_cl+1
      write(fn_dbg_dump_dumpno,*) dbgdumpid_cl
      write(fn_dbg_dump_mpirank,*) tProcInfo_G%rank ! we have also iStep here
      fn_dbg_dump = 'dump_calcBuff.' // trim(adjustl(fn_dbg_dump_mpirank)) // &
                        & '.' // trim(adjustl(fn_dbg_dump_dumpno))
      open(unit=987, file=fn_dbg_dump)
!      print*,'-----'
      do kk=1,iNumberElectrons_G
         write(unit=987,fmt='(1PE20.12e3, 1PE20.12e3, 1PE20.12e3)') sElZ2_G(kk), sElGam_G(kk), sp2(kk)
      end do
!      print*,'-----'
      close(unit=987)
      print*, 'dumped dbg infos to ',fn_dbg_dump
! end dump dbg code

!    print*, 'bz2 length is...', bz2_len
!    print*, 'max p2 is ', maxval(sp2)

      deallocate(sp2)

    else

      bz2_len = (ez2 + 2_ip) * sLengthOfElmZ2_G  ! Just have 2 node boundary for no macroparticles

    end if

!    print*, tProcInfo_G%rank, 'is inside calcBuff, with buffer length', bz2_len

!    bz2 = ez2 + nint(4 * 4 * pi * sRho_G / sLengthOfElmZ2_G)   ! Boundary only 4 lambda_r long - so can only go ~ 3 periods

    bz2 = nint(bz2_len / sLengthOfElmZ2_G)  ! node index of final node in boundary
    print*, 'calcBuff: dz=',dz, ', bz2_len=',bz2_len, ', sLengthOfElmZ2_G=',sLengthOfElmZ2_G
    print*, 'in calcBuff: got bz2=',bz2, ' (before rounding',bz2_len / sLengthOfElmZ2_G,')'

    if (fieldMesh == iPeriodic) then

      bz2PB = 0_ip

      if (bz2 > nz2_G) then

        bz2PB = bz2 - nz2_G
!        if (bz2PB >= fz2) qUnique = .false.
        !bz2 = nz2_G

      end if

    else

      if (bz2 > nz2_G) bz2 = nz2_G
      bz2PB = 0_ip

    end if


! Find global bz2...

    call mpi_allreduce(bz2, bz2_globm, 1, mpi_integer, mpi_max, &
                    tProcInfo_G%comm, error)

    if (tProcInfo_G%rank == tProcInfo_G%size-1) then

!      print*, bz2, bz2PB
      bz2 = bz2_globm

    else

      if (bz2 <= ez2) bz2 = ez2 + 1  ! For sparse beam!!

    end if


    if (fieldMesh == iPeriodic) then

!      print*, '1', bz2

      if (bz2_globm > nz2_G) then
        bz2PB = bz2_globm - nz2_G
      else
        bz2PB = 3_ip
      end if

! tell last process what the max periodic boundary is...
      
!      maxbz2PB = 1_ip
      
      if (tProcInfo_G%qRoot) maxbz2PB = mainlen - 1_ip

!      print*, 'bz2PB', bz2PB

      call mpi_bcast(maxbz2PB, 1, mpi_integer, 0, tProcInfo_G%comm, error)

!      maxbz2PB = 10

      if (bz2PB > maxbz2PB) then

        bz2PB = maxbz2PB

      end if

! if, for any other process, bz2 goes bigger than bz2 on the last process, 
! then it will have to reduce its own bz2 to be OK

      if (tProcInfo_G%rank == tProcInfo_G%size-1) bz2 = ez2 + bz2PB

!      print*, 'bz2 = ', bz2
!      print*, 'bz2PB = ', bz2PB
!      print*, 'ez2 = ', ez2

      bz2last = bz2

      call mpi_bcast(bz2last, 1, mpi_integer, tProcInfo_G%size-1, tProcInfo_G%comm, error)

      if (tProcInfo_G%rank /= tProcInfo_G%size-1) then
        if (bz2 > nz2_g) then
          bz2 = nz2_g
        end if
      end if

      bz2_globm = bz2last

    end if


    if (.not. qUnique) then

      bz2 = bz2_globm
      ez2 = bz2
      mainlen = ez2-fz2+1
      fbufflen = 0
      tllen = mainlen

      allocate(lrank_v(1), rrank_v(1,1), lrfromwhere(1))

    else

      fbuffLen = bz2 - (ez2+1) + 1  ! Local buffer length, NOT including the ez2 node
      tllen = bz2 - fz2 + 1     ! local total length, including buffer





      if (tProcInfo_G%rank == tProcInfo_G%size-1) then
        
        if (fieldMesh == iPeriodic) then

          !mainlen = tllen
!          print*, 'mainlen', mainlen
!          print*, 'tllen', tllen
!          print*, 'nz2_g', nz2_g
!          print*, 'bz2PB', bz2PB
!          print*, 'bz2', bz2
          tllen = mainlen + bz2PB
          fbuffLen = bz2PB
          ez2 = nz2_g !bz2

        else

          mainlen = tllen
          fbuffLen = 0
          ez2 = bz2

        end if

      end if



      call setupLayoutArrs(mainlen, fz2, ez2, ac_ar)  ! readjust ac_ar with new ez2 for last process


      ez2_GGG = ac_ar(tProcInfo_G%size, 3)


      ! count overlap over how many processes....


  !!!   NOW NEED TO RECALC AC_AR TO TAKE INTO ACCOUNT POSSIBLY ADJUSTED
  !!!   BOUNDS ON LAST PROCESS....???

      cpolap = 0

      do ij = 0,tProcInfo_G%size-1

        if  ( (ij > tProcInfo_G%rank) .and. (bz2 >= ac_ar(ij+1, 2)) ) then

          cpolap = cpolap + 1

        end if

      end do



      if (tProcInfo_G%rank /= tProcInfo_G%size-1) then
        allocate(rrank_v(cpolap, 3))
        !allocate(isnd2u(tProcInfo_G%size))
      else
        allocate(rrank_v(1, 3))
        rrank_v = 1
        !allocate(isnd2u(tProcInfo_G%size))
      end if

      yip = 0
      nsnds_bf = cpolap
      !isnd2u = 0




  !  Count how much I'm sending to each process I'm bounding over...

      if (tProcInfo_G%rank /= tProcInfo_G%size-1) then

        do ij = 0,tProcInfo_G%size-1
  !print*, ij
          if  (   (ij > tProcInfo_G%rank) .and. (bz2 >= ac_ar(ij+1, 2)) ) then

            yip = yip + 1

            rrank_v(yip,2) = ac_ar(ij+1, 2)

            if ((fieldMesh == iPeriodic) .and.  (ij == tProcInfo_G%size-1_ip)) then

              rrank_v(yip,3) = bz2
              
            else

              if (bz2 > ac_ar(ij+1, 3)) then
                rrank_v(yip,3) = ac_ar(ij+1, 3)
              else
                rrank_v(yip,3) = bz2
              end if

            end if

            rrank_v(yip,1) = rrank_v(yip,3) - rrank_v(yip,2) + 1

          end if

        end do



      !  send numbers I'm sending to the processes to let them know:

        yip = 0

        do ij = tProcInfo_G%rank + 1, tProcInfo_G%size-1

          yip = yip + 1

          if (ij - tProcInfo_G%rank <= cpolap) then

            !send rrank_v(yip, 1) to tProcInfo_G%rank + yip

            call mpi_issend(rrank_v(yip, 1), 1, mpi_integer, &
                     tProcInfo_G%rank + yip, 0, tProcInfo_G%comm, &
                     req, error)

          else

            !send 0 to tProcInfo_G%rank + yip
            call mpi_issend(0, 1, mpi_integer, &
                     tProcInfo_G%rank + yip, 0, tProcInfo_G%comm, &
                     req, error)

          end if

        end do

      end if

      allocate(drecar(tProcInfo_G%rank))
      ctrecvs = 0

      if (tProcInfo_G%rank /= 0) then

        do ij =  0, tProcInfo_G%rank - 1

          ! dum_recvs from ij

          call mpi_recv(dum_recvs, 1, mpi_integer, ij, &
                  0, tProcInfo_G%comm, statr, error)

          drecar(ij+1) = dum_recvs

          if (dum_recvs > 0) ctrecvs = ctrecvs + 1

        end do

      end if

      if (tProcInfo_G%rank /= tProcInfo_G%size-1) then
        call mpi_wait(req, sendstat, error)
      end if

      if (tProcInfo_G%rank /= 0) then

        allocate(lrank_v(ctrecvs))
        allocate(lrfromwhere(ctrecvs))

      else

        allocate(lrank_v(1))
        allocate(lrfromwhere(1))
        lrank_v = 1
        lrfromwhere = 1

      end if

      nrecvs_bf = ctrecvs

      if (tProcInfo_G%rank /= 0) then

        !nrecvs2me = count(drecar > 0)

        yip = 0

        do ij = 0, tProcInfo_G%rank - 1


          if (drecar(ij+1) > 0) then

            yip = yip+1
            lrank_v(yip) = drecar(ij+1)
            lrfromwhere(yip) = ij  ! rank recieving info from

          end if

        end do

      end if

    end if


!    call mpi_barrier(tProcInfo_G%comm, error)
!    print*, 'SENT AND RECVD BOSS!!!'
!    print*, tProcInfo_G%rank, 'has lrank_v = ', lrank_v!, size(lrank_v), ctrecvs
!    print*, tProcInfo_G%rank, 'has rrank_v = ', rrank_v
!    print*, tProcInfo_G%rank, 'has lrfromwhere = ', lrfromwhere
!    print*, tProcInfo_G%rank, 'has nrecvs_bf = ', nrecvs_bf
!    print*, tProcInfo_G%rank, 'has nsnds_bf = ', nsnds_bf


!    call mpi_finalize(error)
!    stop

!!  !!!!!!! !!!!!  AND NOW EZ2 OF LAST PROCESS SHOULD EQUAL *GLOBAL* BZ2!!!
!!
!!
!!
!!  !!!!!!! !!!!!  SO EQUALS GLOBAL MAXIMUM SO NO ACCIDENTAL OVERLAP INTO BANDIT TERRITORY!!!
!!
!!
!!
!!  !!!!!!! !!!!!  THIS SHOULD PROBABLY BE SET BEFORE THE SEND AND RECV ARRAYS ARE SET UP!!!!



!  ----      OLD
!     Send buffer length to process on the right - as the right process
!     will be updating out local 'buffer' region

!    fbuffLenM = 1
!
!    if (tProcInfo_G%rank /= tProcInfo_G%size-1) then
!
!!        send to rank+1
!
!      call mpi_issend(fbuffLen, 1, mpi_integer, tProcInfo_G%rank+1, 4, &
!             tProcInfo_G%comm, req, error)
!
!    end if
!
!    if (tProcInfo_G%rank /= 0) then
!
!!       rec from rank-1
!
!      CALL mpi_recv( fbuffLenM,1,MPI_INTEGER,tProcInfo_G%rank-1,4, &
!             tProcInfo_G%comm,statr,error )
!
!!      call mpi_wait( statr,sendstat,error )
!
!    end if
!
!    if (tProcInfo_G%rank /= tProcInfo_G%size-1) call mpi_wait( req,sendstat,error )
!
!
!
!
!    call mpi_barrier(tProcInfo_G%comm, error)
!
!    print* , tProcInfo_G%rank, 'is inside calcBuff, with fz2, ez2, bz2 of = ', fz2, ez2, bz2, &
!    'and lens of ', mainlen, tllen, fbuffLen, fbuffLenM
!    -----    OLD

!    call mpi_finalize(error)
!    stop


  end subroutine calcBuff










  subroutine getFStEnd()


    real(kind=wp), allocatable :: sp2(:)
    integer(kind=ip) :: fz2_act, ez2_act

    integer :: error
    integer(kind=ip) :: n_act_g
    integer(kind=ip) :: rbuff

! get global start and end nodes for the active region


! (find min and max electron z2's)



    if (iParaBas == iElectronBased) then

      fz2_act = minval(ceiling(sElZ2_G / sLengthOfElmZ2_G))   ! front z2 node in 'active' region

!      print*, tProcInfo_G%rank, 'and I have fz2_act = ', fz2_act

      CALL mpi_allreduce(fz2_act, rbuff, 1, mpi_integer, &
               mpi_min, tProcInfo_G%comm, error)

!      print*, tProcInfo_G%rank, 'and then my reduced fz2_act = ', rbuff



      fz2_act = rbuff
      fz2_GGG = fz2_act

!print*, tProcInfo_G%rank, 'and so my fz2_act remains = ', fz2_act

!print*, 'fz2_act = ', fz2_act

      ez2_act = maxval(ceiling(sElZ2_G / sLengthOfElmZ2_G) + 1)

!      print*, tProcInfo_G%rank, 'and I have ez2_act = ', ez2_act

      CALL mpi_allreduce(ez2_act, rbuff, 1, mpi_integer, &
               mpi_max, tProcInfo_G%comm, error)

      ez2_act = rbuff
      ez2_GGG = ez2_act

!print*, 'ez2_act = ', ez2_act

    else if (iParaBas == iFieldBased) then    !    FIELD based - also used for initial steps...

      fz2_act = 1_ip
      ez2_act = NZ2_G
      fz2_GGG = 1
      ez2_GGG = 1

    else

      print*, 'NO BASIS FOR PARALLELISM SELECTED!!!'

    end if

    n_act_g = ez2_act - fz2_act + 1


    !print*, tProcInfo_G%rank, 'and then my fz2_act is STILL = ', fz2_act




! get local start and end nodes for the active region

! (use divNodes)


    if (n_act_g < 2*tProcInfo_G%size) then ! If too many nodes

      qUnique = .false.

      if (ioutInfo_G > 0) then
        print*, 'So WHY AM I HERE, WITH nz2 = ', nz2_G
        print*, 'n_act_g = ', n_act_g
        print*, 'fz2_act = ', fz2_act
        print*, 'ez2_act = ', ez2_act
      end if


      fz2 = fz2_GGG
      ez2 = ez2_GGG

      mainlen = n_act_g

    else

      qUnique = .true.

      call divNodes(n_act_g, tProcInfo_G%size, tProcInfo_G%rank, &
                    tllen, fz2, ez2)

      fz2 = fz2 + fz2_act - 1
      ez2 = ez2 + fz2_act - 1

      mainlen = ez2 - fz2 + 1     ! local length, NOT including buffer

    end if

!    print*, 'n_act_g was ', n_act_g
!    print*, 'local now ', tllen, fz2, ez2, fz2_act





  end subroutine getFStEnd



  subroutine getFrBk()

! Get array indices of front and back nodes
! depending on active region nodes


    integer(kind=ip) :: efz2_MG, ebz2_MG
    integer :: error

      if (tProcInfo_G%qRoot) efz2_MG = fz2 - 1

      call MPI_BCAST(efz2_MG,1, mpi_integer, 0, &
                      tProcInfo_G%comm,error)



      if (fieldMesh == iPeriodic) then

        tlflen_glob = 0
        tlflen = 0
        tlflen4arr = 1
        ffs = 0
        ffe = 0
        ffs_GGG = 0
        ffe_GGG = 0

      else

        if (efz2_MG < 1) then

!     then there is no front section of the field...

          tlflen_glob = 0
          tlflen = 0
          tlflen4arr = 1
          ffs = 0
          ffe = 0
          ffs_GGG = 0
          ffe_GGG = 0

        else if (efz2_MG > 0) then

          tlflen_glob = efz2_MG

          call divNodes(efz2_MG,tProcInfo_G%size, &
                        tProcInfo_G%rank, &
                        tlflen, ffs, ffe)

          tlflen4arr = tlflen

          ffs_GGG = 1
          ffe_GGG = efz2_MG


        end if

      end if

      CALL MPI_ALLGATHER(tlflen, 1, MPI_INTEGER, &
              ff_ar(:,1), 1, MPI_INTEGER, &
              tProcInfo_G%comm, error)

      CALL MPI_ALLGATHER(ffs, 1, MPI_INTEGER, &
              ff_ar(:,2), 1, MPI_INTEGER, &
              tProcInfo_G%comm, error)

      CALL MPI_ALLGATHER(ffe, 1, MPI_INTEGER, &
              ff_ar(:,3), 1, MPI_INTEGER, &
              tProcInfo_G%comm, error)




!    print*, 'FRONT ARRAY IS ', ff_ar




      ! get rightmost bz2 ...(last process)
      ! ebz2_MG - extreme back z2 node of active region plus 1

      if (tProcInfo_G%rank == tProcInfo_G%size-1) ebz2_MG = bz2 + 1


      call MPI_BCAST(ebz2_MG,1, mpi_integer, tProcInfo_G%size-1, &
                      tProcInfo_G%comm,error)



      if (fieldMesh == iPeriodic) then

        tlelen_glob = 0
        tlelen = 0
        tlelen4arr = 1
        ees = 0
        eee = 0
        ees_GGG = 0
        eee_GGG = 0

      else

        if (ebz2_MG > NZ2_G) then

!     then there is no back section of the field...

          tlelen_glob = 0
          tlelen = 0
          tlelen4arr = 1
          ees = 0
          eee = 0

        else if (ebz2_MG < nz2_G + 1) then

          tlelen_glob = nz2_G - ebz2_MG + 1

!        print*, 'I get the tlelen_glob to be ', tlelen_glob

          call divNodes(tlelen_glob,tProcInfo_G%size, &
                        tProcInfo_G%rank, &
                        tlelen, ees, eee)

          ees = ees + ebz2_MG - 1
          eee = eee + ebz2_MG - 1

          ees_GGG = ebz2_MG
          eee_GGG = NZ2_G

          tlelen4arr = tlelen

!        print*, '...and the start nd end of the back to be', ees, eee

        end if

      end if

      CALL MPI_ALLGATHER(tlelen, 1, MPI_INTEGER, &
              ee_ar(:,1), 1, MPI_INTEGER, &
              tProcInfo_G%comm, error)

      CALL MPI_ALLGATHER(ees, 1, MPI_INTEGER, &
              ee_ar(:,2), 1, MPI_INTEGER, &
              tProcInfo_G%comm, error)

      CALL MPI_ALLGATHER(eee, 1, MPI_INTEGER, &
              ee_ar(:,3), 1, MPI_INTEGER, &
              tProcInfo_G%comm, error)

!        print*, '...so back array = ', ee_ar



  end subroutine getFrBk


  subroutine redist2new2(old_dist, new_dist, field_old, field_new)

  implicit none

! Alternative subroutine to redistribute the field values in field_old
! to field_new. The layout of the field in field_old is
! described in old_dist, and the layout of the new field
! is described in new_dist. This subroutine uses mpi_alltoallv, in
! contrast to redist2new which uses mpi the sends and recvs

! inputs

    integer(kind=ip), intent(in) :: old_dist(:,:), new_dist(:,:)
    real(kind=wp), intent(inout) :: field_old(:), field_new(:)

! local

    integer(kind=ip) :: iproc_s, iproc_r
    integer(kind=ip) :: st_ind_new, ed_ind_new, &
                        st_ind_old, ed_ind_old, &
                        nbase, obase
    integer(kind=ip), allocatable :: send_ptrs(:,:), recv_ptrs(:,:)

    integer(kind=ip), allocatable :: sdispls(:), rdispls(:)


    integer(kind=ip), allocatable :: nsends(:), nrecvs(:)
    integer :: error, req, ij
    integer statr(MPI_STATUS_SIZE)
    integer sendstat(MPI_STATUS_SIZE)



    allocate(send_ptrs(tProcInfo_G%size, 3))
    allocate(recv_ptrs(tProcInfo_G%size, 3))

    allocate(sdispls(tProcInfo_G%size))
    allocate(rdispls(tProcInfo_G%size))

    allocate(nsends(tProcInfo_G%size), nrecvs(tProcInfo_G%size))

    call golaps(old_dist(tProcInfo_G%rank+1,2), &
                old_dist(tProcInfo_G%rank+1,3), &
                new_dist, send_ptrs)

    call golaps(new_dist(tProcInfo_G%rank+1,2), &
                new_dist(tProcInfo_G%rank+1,3), &
                old_dist, recv_ptrs)



    nsends = send_ptrs(:,1) * ntrnds_G
    nrecvs = recv_ptrs(:,1) * ntrnds_G

!            nbase = new_dist(iproc_r+1, 2) - 1

!            st_ind_new = send_ptrs(iproc_r+1, 2) - nbase
!            st_ind_new = (st_ind_new - 1)* ntrnds_G + 1



!    send_ptrs(iproc_r+1, 2) - nbase



    sdispls = ( (send_ptrs(:,2) - (old_dist(tProcInfo_G%rank+1, 2) - 1) ) - 1_ip) * ntrnds_G


!    do ij = 1, tProcInfo_G%size

!      if ((ij == 1) .and. () )

!      sdispls(ij) = ( (send_ptrs(ij,2) - (new_dist(ij, 2) - 1) ) - 1_ip) * ntrnds_G

!    end do



    rdispls = ( (recv_ptrs(:,2) - (new_dist(tProcInfo_G%rank+1, 2) - 1) ) - 1_ip) * ntrnds_G

    do ij = 1, tProcInfo_G%size

      if (send_ptrs(ij,1) == 0) then

        if (ij-1 == 0) then

          sdispls(ij) = 0_ip

        else

          sdispls(ij) = sdispls(ij-1)! + nsends(ij-1)

        end if

      end if

    end do


    do ij = 1, tProcInfo_G%size

      if (recv_ptrs(ij,1) == 0) then

        if (ij-1 == 0) then

          rdispls(ij) = 0_ip

        else

          rdispls(ij) = rdispls(ij-1)! + nrecvs(ij-1)

        end if

      end if

    end do


!    print*, tProcInfo_G%rank, 'nrecvs = ', nrecvs
!    print*, tProcInfo_G%rank, 'rdispls = ', rdispls
!    print*, tProcInfo_G%rank, 'recv_ptrs(:,2) = ', recv_ptrs(:,2)
!    print*, tProcInfo_G%rank, 'nsends = ', nsends
!    print*, tProcInfo_G%rank, 'sdispls = ', sdispls
!    print*, tProcInfo_G%rank, 'send_ptrs(:,2) = ', send_ptrs(:,2)

!    call mpi_barrier(tProcInfo_G%comm, error)

    call mpi_alltoallv(field_old, nsends, sdispls, mpi_double_precision, &
                       field_new, nrecvs, rdispls, mpi_double_precision, &
                       tProcInfo_G%comm, error)


    deallocate(nsends, nrecvs)
    deallocate(send_ptrs, recv_ptrs)
    deallocate(sdispls, rdispls)

!    print*, 'called me NOW'

!    call mpi_barrier(tProcInfo_G%comm, error)
!    call mpi_finalize(error)
!    stop

  end subroutine redist2new2










  subroutine redist2new(old_dist, new_dist, field_old, field_new)


! Subroutine to redistribute the field values in field_old
! to field_new. The layout of the field in field_old is
! described in old_dist, and the layout of the new field
! is described in new_dist.

    ! inputs

    integer(kind=ip), intent(in) :: old_dist(:,:), new_dist(:,:)
    real(kind=wp), intent(inout) :: field_old(:), field_new(:)

    ! local

    integer(kind=ip) :: iproc_s, iproc_r
    integer(kind=ip) :: st_ind_new, ed_ind_new, &
                        st_ind_old, ed_ind_old, &
                        nbase, obase
    integer(kind=ip), allocatable :: send_ptrs(:,:)

    integer :: error, req
    integer statr(MPI_STATUS_SIZE)
    integer sendstat(MPI_STATUS_SIZE)



    allocate(send_ptrs(tProcInfo_G%size, 3))

    ! calc overlaps from MPI process 'iproc_s',
    ! then loop round, if size_olap>0 then if
    ! rank==iproc_s send, else if rank==iproc_r
    ! recv, unless iproc_r==iproc_s then just
    ! direct assignment


!    if (tProcInfo_G%qroot) print*, 'NOW, for new dist described by ', new_dist,'....', &
!                               ' and old dist of ', old_dist

    do iproc_s = 0, tProcInfo_G%size-1   !  maybe do iproc_s = rank, rank-1 (looped round....)

      call golaps(old_dist(iproc_s+1,2), old_dist(iproc_s+1,3), new_dist, send_ptrs)

!      if (tProcInfo_G%qroot) print*, 'olaps are ', send_ptrs, 'for old nodes ', old_dist(iproc_s+1,2), &
!          'to', old_dist(iproc_s+1,3)

!      call mpi_barrier(tProcInfo_G%comm, error)

      do iproc_r = 0, tProcInfo_G%size-1

        if (send_ptrs(iproc_r+1,1) > 0 ) then

          if ((tProcInfo_G%rank == iproc_r) .and. (iproc_r == iproc_s) ) then

            ! assign directly

            obase = old_dist(iproc_r+1, 2) - 1
            nbase = new_dist(iproc_r+1, 2) - 1

            st_ind_new = send_ptrs(iproc_r+1, 2) - nbase
            st_ind_new = (st_ind_new - 1)* ntrnds_G + 1

            ed_ind_new = send_ptrs(iproc_r+1, 3) - nbase
            ed_ind_new = ed_ind_new * ntrnds_G

            st_ind_old = send_ptrs(iproc_r+1, 2) - obase
            st_ind_old = (st_ind_old - 1) * ntrnds_G + 1

            ed_ind_old = send_ptrs(iproc_r+1, 3) - obase
            ed_ind_old = ed_ind_old * ntrnds_G


!            print*, 'AD st_ind_old = ', st_ind_old, ed_ind_old
!            print*, 'AD st_ind_new = ', st_ind_new, ed_ind_new

            field_new(st_ind_new:ed_ind_new) = field_old(st_ind_old:ed_ind_old)

          else

            obase = old_dist(iproc_s+1, 2) - 1
            nbase = new_dist(iproc_r+1, 2) - 1

            st_ind_new = send_ptrs(iproc_r+1, 2) - nbase
            st_ind_new = (st_ind_new - 1)* ntrnds_G + 1

            ed_ind_new = send_ptrs(iproc_r+1, 3) - nbase
            ed_ind_new = ed_ind_new * ntrnds_G

            st_ind_old = send_ptrs(iproc_r+1, 2) - obase
            st_ind_old = (st_ind_old - 1) * ntrnds_G + 1

            ed_ind_old = send_ptrs(iproc_r+1, 3) - obase
            ed_ind_old = ed_ind_old * ntrnds_G


            if (tProcInfo_G%rank == iproc_s) then

!              print*, 'SD st_ind_old = ', st_ind_old, ed_ind_old, size(field_old), &
!              send_ptrs(iproc_r+1,1)

              call mpi_issend(field_old(st_ind_old:ed_ind_old), &
                          send_ptrs(iproc_r+1,1)*ntrnds_G, &
                          mpi_double_precision, iproc_r, 0, tProcInfo_G%comm, req, error)

!              print*, 'SENDING', field_old(st_ind_old:ed_ind_old)

            else if (tProcInfo_G%rank == iproc_r) then

!              print*, 'SD st_ind_new = ', st_ind_new, ed_ind_new, size(field_new), &
!                           send_ptrs(iproc_r+1,1)

              call mpi_recv(field_new(st_ind_new:ed_ind_new), &
                            send_ptrs(iproc_r+1,1)*ntrnds_G, &
                            mpi_double_precision, iproc_s, 0, tProcInfo_G%comm, statr, error)

!              print*, 'RECIEVED', field_new(st_ind_new:ed_ind_new)

            end if

            !if (tProcInfo_G%rank == iproc_s) call mpi_wait( req,sendstat,error )
  !          call mpi_barrier(tProcInfo_G%comm, error)

   !         call mpi_finalize(error)
   !         stop


          end if

        end if

      end do

!    if (tProcInfo_G%rank == iproc_s) call mpi_wait( req,sendstat,error )

    end do

    deallocate(send_ptrs)

    call mpi_barrier(tProcInfo_G%comm, error)

   end subroutine redist2new




  subroutine setupLayoutArrs(len, st_ind, ed_ind, arr)

!
! Subroutine to setup the arrays storing the size, start and
! end pointers of the local field arrays.
!

    integer(kind=ip), intent(inout) :: len, st_ind, ed_ind, arr(:,:)
    integer :: error


    CALL MPI_ALLGATHER(len, 1, MPI_INTEGER, &
            arr(:,1), 1, MPI_INTEGER, &
            tProcInfo_G%comm, error)

    CALL MPI_ALLGATHER(st_ind, 1, MPI_INTEGER, &
            arr(:,2), 1, MPI_INTEGER, &
            tProcInfo_G%comm, error)

    CALL MPI_ALLGATHER(ed_ind, 1, MPI_INTEGER, &
            arr(:,3), 1, MPI_INTEGER, &
            tProcInfo_G%comm, error)

  end subroutine setupLayoutArrs



  subroutine rearrElecs()

  implicit none

  integer :: error
  integer(kind=ip) :: iproc, iproc_r, iproc_s
  integer(kind=ip), allocatable :: cnt2proc(:), &
                                   inds4sending(:)
  real(kind=wp), allocatable :: sElZ2_OLD(:), sElX_OLD(:), &
                                sElY_OLD(:), sElGam_OLD(:), &
                                sElPX_OLD(:), sElPY_OLD(:), &
                                s_chi_bar_OLD(:), &
                                s_Normalised_chi_OLD(:), &
                                tmp4sending(:)

  integer(kind=ip) :: icds, new_sum, offe, offs, frmroot


    ! p_nodes type calc from jRHS...

    ! send_count = count(p_nodes == rank)
    ! where(p_nodes == rank)

! %%%%%%%%%%%%%%%%%%%
    ! so get p_nodes_loc

    allocate(cnt2proc(tProcInfo_G%size))
    cnt2proc = 0

!    do imp = 1,iNumberElectrons_G

!      where ( (sElZ2_G(imp) >= (sLengthOfElmZ2_G * (ac_ar(:,2)-1))) .and. &
!                  (sElZ2_G(imp) >= (sLengthOfElmZ2_G * (ac_ar(:,3)-1) )) )

!        cnt2proc = cnt2proc + 1

!      end where

!    end do

! OR
    do iproc = 0, tProcInfo_G%size-1

      icds = count(sElZ2_G > (sLengthOfElmZ2_G * (ac_ar(iproc+1, 2)-1)) .and. &
                    (sElZ2_G <= (sLengthOfElmZ2_G * ac_ar(iproc+1, 3))) )

      cnt2proc(iproc+1) = icds   ! amount I'm sending to iproc

      call mpi_reduce(cnt2proc(iproc+1), new_sum, 1, &
                     mpi_integer, mpi_sum, iproc, tProcInfo_G%comm, error)

    end do


    call mpi_barrier(tProcInfo_G%comm, error)

!    print*, 'cnt2proc = ', cnt2proc


!    call mpi_finalize(error)
!    stop

!    do iproc = 0, tProcInfo_G%size-1

      ! mpi sum to iproc total coming to it
      ! cnt2proc summed to new_sum

!    end do

    allocate(sElZ2_OLD(iNumberElectrons_G))
    sElZ2_OLD = sElZ2_G

    deallocate(sElZ2_G)

    allocate(sElZ2_G(new_sum))



    allocate(sElGam_OLD(iNumberElectrons_G))
    sElGam_OLD = sElGam_G

    deallocate(sElGam_G)

    allocate(sElGam_G(new_sum))



    allocate(sElX_OLD(iNumberElectrons_G))
    sElX_OLD = sElX_G

    deallocate(sElX_G)

    allocate(sElX_G(new_sum))



    allocate(sElY_OLD(iNumberElectrons_G))
    sElY_OLD = sElY_G

    deallocate(sElY_G)

    allocate(sElY_G(new_sum))



    allocate(sElPX_OLD(iNumberElectrons_G))
    sElPX_OLD = sElPX_G

    deallocate(sElPX_G)

    allocate(sElPX_G(new_sum))



    allocate(sElPY_OLD(iNumberElectrons_G))
    sElPY_OLD = sElPY_G

    deallocate(sElPY_G)

    allocate(sElPY_G(new_sum))



    allocate(s_chi_bar_OLD(iNumberElectrons_G))
    s_chi_bar_OLD = s_chi_bar_G

    deallocate(s_chi_bar_G)

    allocate(s_chi_bar_G(new_sum))



    iNumberElectrons_G = new_sum
!    print*, 'new num elecs is ', new_sum

!    allocate(frmroot(tProcInfo_G%size))
    allocate(tmp4sending(maxval(cnt2proc)))
    allocate(inds4sending(maxval(cnt2proc)))

    inds4sending = 0
    tmp4sending = 0

    offs=0
    offe=0

    do iproc_s = 0, tProcInfo_G%size-1

    ! mpi scatter from iproc_s to others

      frmroot = 0

      call mpi_scatter(cnt2proc, 1, mpi_integer, frmroot, &
                       1, mpi_integer, iproc_s, tProcInfo_G%comm, &
                       error)

        ! mpi_send electrons - z2, gamma, etc


    call mpi_barrier(tProcInfo_G%comm, error)



      if (tProcInfo_G%rank == iproc_s) then

        do iproc_r = 0, tProcInfo_G%size-1


          if (cnt2proc(iproc_r+1) > 0) then

            if (iproc_r == iproc_s) then

              ! Assign locally

              offs = offe + 1
              offe = offs + cnt2proc(iproc_r+1) - 1

              call getinds(inds4sending(1:cnt2proc(iproc_r+1)), &
                    sElZ2_OLD, &
                    (sLengthOfElmZ2_G * (ac_ar(iproc_r+1,2)-1)), &
                    (sLengthOfElmZ2_G * ac_ar(iproc_r+1,3)) )

              !print*, inds4sending(1:cnt2proc(iproc_r+1))
              !print*, 'cnt2proc again:', cnt2proc(iproc_r+1)

              sElZ2_G(offs:offe) = sElZ2_OLD(inds4sending(1:cnt2proc(iproc_r+1)))
              sElGam_G(offs:offe) = sElGam_OLD(inds4sending(1:cnt2proc(iproc_r+1)))
              sElPX_G(offs:offe) = sElPX_OLD(inds4sending(1:cnt2proc(iproc_r+1)))
              sElPY_G(offs:offe) = sElPY_OLD(inds4sending(1:cnt2proc(iproc_r+1)))
              sElX_G(offs:offe) = sElX_OLD(inds4sending(1:cnt2proc(iproc_r+1)))
              sElY_G(offs:offe) = sElY_OLD(inds4sending(1:cnt2proc(iproc_r+1)))
              s_chi_bar_G(offs:offe) = s_chi_bar_OLD(inds4sending(1: &
                                                   cnt2proc(iproc_r+1)))


            else

              ! SEND to iproc_r

              call getinds(inds4sending(1:cnt2proc(iproc_r+1)), &
                    sElZ2_OLD, &
                    (sLengthOfElmZ2_G * (ac_ar(iproc_r+1,2)-1) ), &
                    (sLengthOfElmZ2_G * ac_ar(iproc_r+1,3)) )

!              tmp4sending(1:cnt2proc(iproc_r+1)) = sElZ2_OLD((1:cnt2proc(iproc_r+1)))

!              call mpi_issend(tmp4sending(1:cnt2proc(iproc_r+1)), cnt2proc(iproc_r+1), mpi_real, &
!                               iproc_r, tProcInfo_G%comm, req, error)

              call sendArrPart(sElZ2_OLD, inds4sending(1:cnt2proc(iproc_r+1)), &
                               cnt2proc(iproc_r+1), &
                               tmp4sending, iproc_r)

              call sendArrPart(sElGam_OLD, inds4sending(1:cnt2proc(iproc_r+1)), &
                               cnt2proc(iproc_r+1), &
                               tmp4sending, iproc_r)

              call sendArrPart(sElPX_OLD, inds4sending(1:cnt2proc(iproc_r+1)), &
                               cnt2proc(iproc_r+1), &
                               tmp4sending, iproc_r)

              call sendArrPart(sElPY_OLD, inds4sending(1:cnt2proc(iproc_r+1)), &
                               cnt2proc(iproc_r+1), &
                               tmp4sending, iproc_r)

              call sendArrPart(sElX_OLD, inds4sending(1:cnt2proc(iproc_r+1)), &
                               cnt2proc(iproc_r+1), &
                               tmp4sending, iproc_r)

              call sendArrPart(sElY_OLD, inds4sending(1:cnt2proc(iproc_r+1)), &
                               cnt2proc(iproc_r+1), &
                               tmp4sending, iproc_r)

              call sendArrPart(s_chi_bar_OLD, inds4sending(1:cnt2proc(iproc_r+1)), &
                               cnt2proc(iproc_r+1), &
                               tmp4sending, iproc_r)

                !       call mpi_issend(fz2, 1, mpi_integer, tProcInfo_G%rank-1, 0, &
!            tProcInfo_G%comm, req, error)


            end if

          end if

        end do


      else

        if (frmroot>0) then


          offs = offe + 1
          offe = offs + frmroot - 1


          call recvArrPart(sElZ2_G, frmroot, &
                           offs, offe, iproc_s)

          call recvArrPart(sElGam_G, frmroot, &
                           offs, offe, iproc_s)

          call recvArrPart(sElPX_G, frmroot, &
                           offs, offe, iproc_s)

          call recvArrPart(sElPY_G, frmroot, &
                           offs, offe, iproc_s)

          call recvArrPart(sElX_G, frmroot, &
                           offs, offe, iproc_s)

          call recvArrPart(sElY_G, frmroot, &
                           offs, offe, iproc_s)

          call recvArrPart(s_chi_bar_G, frmroot, &
                           offs, offe, iproc_s)

        end if

      end if

    end do



    ! count send_to_each_process

    ! loop over processes

      ! call mpi_scatter(root=iproc, send_to_each_process, to recv_buff)

      ! if recv_buff>0 call mpi_recv(from iproc)

      ! loop lor_proc over processes
        ! if send_to_each_process(lor_proc) > 0  call mpi_send(to lor_proc)







    deallocate(cnt2proc)
    deallocate(tmp4sending)
    deallocate(inds4sending)
!    deallocate(frmroot)



    deallocate(sElZ2_OLD, sElX_OLD, &
               sElY_OLD, sElGam_OLD, &
               sElPX_OLD, sElPY_OLD, &
               s_chi_bar_OLD)



  end subroutine rearrElecs






  subroutine getinds(inds, array, lower, upper)

  ! getInds
  !
  ! Subroutine to return the indices of elements in the array
  ! which lie between the upper and lower bounds.
  !
  !
  !
  !

    integer(kind=ip), intent(out) :: inds(:)
    real(kind=wp), intent(in) :: array(:)
    real(kind=wp), intent(in) :: lower, upper

    integer(kind=ip) :: nx, ij, co

    nx = size(array)
    co = 0

    do ij = 1, nx

      if ((array(ij) > lower) .and. (array(ij) <= upper) ) then
        co = co+1
        inds(co) = ij
      end if

    end do

  end subroutine getinds



  subroutine sendArrPart(array, inds, cnt, tmparray, iproc)

!
! Subroutine to send part of an array specified by
! the indices in 'inds'.
!
! cnt - count of the number of elements to be sent
! inds - integer array of the indices of array to be sent
! array - real number array of values, of which only part will be
!         sent as specified in inds
! tmparray - An array used to temporarily store the values of
!            'array' to be sent - should be AT LEAST of size
!            cnt, but may be larger.
!


    real(kind=wp), intent(in) :: array(:)
    real(kind=wp), intent(inout) :: tmparray(:)
    integer(kind=ip), intent(in) :: inds(:)
    integer(kind=ip), intent(in) :: cnt
    integer(kind=ip), intent(inout) :: iproc

    integer :: req, error
    integer :: sendstat(MPI_STATUS_SIZE)

    tmparray(1:cnt) = array(inds)

    call mpi_issend(tmparray(1:cnt), cnt, mpi_double_precision, &
                   iproc, 0, tProcInfo_G%comm, req, error)

    call mpi_wait( req,sendstat,error )

  end subroutine sendArrPart


  subroutine recvArrPart(array, cnt, st_ind, ed_ind, iproc)

! Recv section of array, specified by start and end
! indices st_ind and ed_ind.
!
!

    real(kind=wp), intent(inout) :: array(:)
    integer(kind=ip), intent(inout) :: cnt, iproc
    integer(kind=ip), intent(in) :: st_ind, ed_ind

    integer :: error
    integer statr(MPI_STATUS_SIZE)


    call mpi_recv(array(st_ind:ed_ind), cnt, &
                  mpi_double_precision, iproc, &
                  0, tProcInfo_G%comm, statr, error)

  end subroutine recvArrPart


!!!!~#####################################################################################



  subroutine redist2FFTWlt()

    implicit none

    integer(kind=ip) :: tmpfz2, tmpez2, tmpmainlen, &
                        tmpbz2, tmptllen, tmpfz2_act, &
                        tmpez2_act






    tmpfz2 = tTransInfo_G%loc_z2_start + 1
    tmpez2 = tTransInfo_G%loc_z2_start + &
              tTransInfo_G%loc_nz2

    tmpmainlen = tTransInfo_G%loc_nz2
    tmpbz2 = tmpez2
    tmptllen = tmpmainlen
    tmpfz2_act = 1
    tmpez2_act = nz2_G


    allocate(tre_fft(tmpmainlen*ntrnds_G), &
             tim_fft(tmpmainlen*ntrnds_G))


    tre_fft = 0_wp
    tim_fft = 0_wp


    allocate(ft_ar(tProcInfo_G%size, 3))
    call setupLayoutArrs(tmpmainlen, tmpfz2, tmpez2, ft_ar)

!    print*, 'fft array layout is ', ft_ar


    call redist2new2(ff_ar, ft_ar, fr_rfield, tre_fft)
    call redist2new2(ff_ar, ft_ar, fr_ifield, tim_fft)


    call redist2new2(ee_ar, ft_ar, bk_rfield, tre_fft)
    call redist2new2(ee_ar, ft_ar, bk_ifield, tim_fft)



    call redist2new2(ac_ar, ft_ar, ac_rfield, tre_fft)
    call redist2new2(ac_ar, ft_ar, ac_ifield, tim_fft)


  end subroutine redist2FFTWlt






  subroutine redistbackFFT()

    implicit none
    
    integer :: req, error
    integer(kind=ip) :: ij, si, sst, sse
    integer statr(MPI_STATUS_SIZE)
    integer sendstat(MPI_STATUS_SIZE)

    call redist2new2(ft_ar, ff_ar, tre_fft, fr_rfield)
    call redist2new2(ft_ar, ff_ar, tim_fft, fr_ifield)


    call redist2new2(ft_ar, ee_ar, tre_fft, bk_rfield)
    call redist2new2(ft_ar, ee_ar, tim_fft, bk_ifield)



    call redist2new2(ft_ar, ac_ar, tre_fft, ac_rfield)
    call redist2new2(ft_ar, ac_ar, tim_fft, ac_ifield)


    deallocate(tre_fft, tim_fft)
    deallocate(ft_ar)


    if (fieldMesh == iPeriodic) then

      si = (nx_g * ny_g) * (bz2PB + 1_ip)
      sst = ((tllen - (bz2PB+1_ip) ) * (nx_g * ny_g)) + 1_ip
      sse = tllen * (nx_g * ny_g)

      if (tProcInfo_G%rank == 0_ip) then

        call mpi_issend(ac_rfield(1:si), &
                        si, &
                        mpi_double_precision, &
                        tProcInfo_G%size-1_ip, 0, &
                        tProcInfo_G%comm, req, error)

      end if



      if (tProcInfo_G%rank == tProcInfo_G%size-1_ip) then
   
        call mpi_recv( ac_rfield(sst:sse), &
                 si, mpi_double_precision, &
                 0, 0, tProcInfo_G%comm, &
                 statr, error )

      end if


      if (tProcInfo_G%rank == 0_ip) then

        call mpi_wait( req,sendstat,error )
        call mpi_issend(ac_ifield(1:si), &
                        si, &
                        mpi_double_precision, &
                        tProcInfo_G%size-1_ip, 0, &
                        tProcInfo_G%comm, req, error)
   
      end if



   
      if (tProcInfo_G%rank == tProcInfo_G%size-1_ip) then

        call mpi_recv( ac_ifield(sst:sse), &
                 si, mpi_double_precision, &
                 0, 0, tProcInfo_G%comm, &
                 statr, error )
   
      end if
   

   
      if (tProcInfo_G%rank == 0_ip) then

        call mpi_wait( req,sendstat,error )
   
      end if

    end if

  end subroutine redistbackFFT



end module ParaField
